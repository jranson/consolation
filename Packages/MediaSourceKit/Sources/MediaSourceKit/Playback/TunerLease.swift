import Foundation
import HTTPMPEG2Kit
import PlaybackKit
import Synchronization

/// The tuner lease of a live channel, and the TS engine's way to reach the channel.
///
/// It holds the subscription `HDHomeRunSource.playback(for:request:)` opened and hands it to the engine's first
/// connection, so starting playback costs no second GET. Every reconnect subscribes again through the broker, and
/// the lease follows it: `release()` cancels whichever subscription is current, and no reconnect opens one after
/// that. Stopping the engine cancels the current subscription too; both are idempotent.
///
/// It is opaque on purpose. The broker and the `TuneRequest`, whose routes carry the devices' stream URLs, stay
/// inside, so a holder of a descriptor (the player layer) never sees an HDHomeRun URL, not even through `dump()`.
public nonisolated final class TunerLease: PlaybackLease, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    private struct Reconnect {
        let broker: TunerBroker
        let request: TuneRequest
        let slot: SubscriberSlot
    }

    private struct State {
        /// The subscription that opened the channel, until the engine's first connection takes it.
        var initial: ChannelSubscription?
        /// The connection the engine reads now.
        var current: ChannelSubscriptionByteSource?
        var isReleased = false
    }

    private enum Attempt {
        case source(ChannelSubscriptionByteSource, replacing: ChannelSubscriptionByteSource?)
        case released
        case noReconnect
    }

    /// The channel this lease holds a tuner for.
    public let channel: ChannelKey
    /// Where the channel opened: the device and tuner, never a URL. A reconnect may land on another device.
    public let route: StreamRoute
    private let opened: ChannelSubscription
    private let reconnect: Reconnect?
    private let state: Mutex<State>

    /// A lease whose engine can't reconnect: the second connection attempt fails.
    public convenience init(subscription: ChannelSubscription) {
        self.init(subscription: subscription, reconnect: nil)
    }

    /// A lease whose engine reconnects by subscribing to `request` again through `broker`, in the same `slot` the
    /// subscription was opened in. The broker replaces the slot's previous subscription before it sends the next GET
    /// (close before open), and fails over through the request's routes.
    public convenience init(subscription: ChannelSubscription, broker: TunerBroker, request: TuneRequest,
                            slot: SubscriberSlot = .player) {
        self.init(subscription: subscription, reconnect: Reconnect(broker: broker, request: request, slot: slot))
    }

    private init(subscription: ChannelSubscription, reconnect: Reconnect?) {
        channel = subscription.route.channel
        route = subscription.route
        opened = subscription
        self.reconnect = reconnect
        state = Mutex(State(initial: subscription))
    }

    /// The program the first connection selects from the PAT; set when the channel opened on a full multiplex. A
    /// reconnect may land on a program stream (or another multiplex): the engine reads each connection's own
    /// `ByteSource.programNumber`.
    public var programNumber: Int? { route.programNumber }

    /// True once `release()` was called.
    public var isReleased: Bool { state.withLock { $0.isReleased } }

    /// Cancels the current subscription (and so frees the tuner once no one else watches the channel) and refuses
    /// every later connection attempt.
    public func release() async {
        let (initial, current) = state.withLock { state in
            state.isReleased = true
            defer {
                state.initial = nil
                state.current = nil
            }
            return (state.initial, state.current)
        }
        initial?.cancel()
        current?.cancel()
        opened.cancel()
    }

    /// The source for the engine's next connection attempt: the open subscription first, then a new broker
    /// subscription per reconnect. After `release()` it fails at once with a cancelled error, which the engine
    /// doesn't retry.
    func makeSource(expectsRelease: Bool) -> any ByteSource {
        let attempt = state.withLock { state -> Attempt in
            guard !state.isReleased else { return .released }
            let next: ChannelSubscriptionByteSource
            if let initial = state.initial {
                state.initial = nil
                next = ChannelSubscriptionByteSource(subscription: initial)
            } else if let reconnect {
                next = ChannelSubscriptionByteSource(broker: reconnect.broker, request: reconnect.request,
                                                     slot: reconnect.slot, expectsRelease: expectsRelease)
            } else {
                return .noReconnect
            }
            defer { state.current = next }
            return .source(next, replacing: state.current)
        }
        switch attempt {
        case let .source(source, previous):
            // The engine cancels a connection before it reconnects; this keeps one connection per lease regardless.
            previous?.cancel()
            return source
        case .released:
            return UnavailableByteSource(error: ChannelSubscriptionByteSource.playbackError(.cancelled))
        case .noReconnect:
            return UnavailableByteSource(error: PlaybackError(
                kind: .source, title: "The channel can't be reopened.", domain: "MediaSourceKit"))
        }
    }

    /// The request reconnects subscribe to; for tests in this package only.
    var reconnectRequest: TuneRequest? { reconnect?.request }

    /// The slot reconnects subscribe in; for tests in this package only.
    var reconnectSlot: SubscriberSlot? { reconnect?.slot }

    public var description: String { "TunerLease(\(channel))" }

    public var debugDescription: String { description }

    /// The channel only: no broker, request or device URL.
    public var customMirror: Mirror {
        Mirror(self, children: ["channel": channel.description, "isReleased": isReleased])
    }
}
