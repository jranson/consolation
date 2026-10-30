import Foundation
import HTTPMPEG2Kit
import PlaybackKit
import Synchronization

/// One connection attempt of the TS engine for a live channel: adapts a `TunerBroker` channel subscription to
/// PlaybackKit's `ByteSource`, so the engine reads a channel without ever seeing its URL, and translates tuner
/// errors (805 "all tuners in use", 807 "no signal", …) into user-facing playback errors.
///
/// It either subscribes through the broker in `open()` or adopts a subscription that is already open (the one a
/// `TunerLease` holds). `cancel()` releases the subscription and so the tuner.
///
/// The engine builds a new source for every reconnect (after 1 s and 3 s). That never holds two tuners: the broker
/// replaces the slot's previous subscription before it sends the next GET (or joins the channel's open upstream),
/// whichever of the old source's `cancel()` and the new source's `open()` happens first. Each multi-view tile uses
/// its own slot, so one tile's reconnect never ends another tile's (or the player's) stream.
///
/// After `open()` returns, `programNumber` says which program to select from the PAT: set when the broker joined
/// or opened a full multiplex shared with other channels, nil for a program stream.
public nonisolated final class ChannelSubscriptionByteSource: ByteSource {
    private enum Origin {
        case broker(TunerBroker, TuneRequest, slot: SubscriberSlot, expectsRelease: Bool)
        case adopted
    }

    private struct State {
        var subscription: ChannelSubscription?
        var isCancelled = false
    }

    private let origin: Origin
    private let state: Mutex<State>

    /// Subscribes in `open()`.
    /// - Parameters:
    ///   - slot: the player (`.player`) or a multi-view tile (`.tile(id)`); a slot holds one subscription.
    ///   - expectsRelease: a tuner held for us elsewhere (a relay host that just stopped) is being freed, so a busy
    ///     answer in the next moment is retried once.
    public init(broker: TunerBroker, request: TuneRequest, slot: SubscriberSlot = .player,
                expectsRelease: Bool = false) {
        origin = .broker(broker, request, slot: slot, expectsRelease: expectsRelease)
        state = Mutex(State())
    }

    /// Reads a subscription that is already open. `open()` may be called once.
    public init(subscription: ChannelSubscription) {
        origin = .adopted
        state = Mutex(State(subscription: subscription))
    }

    public func open() async throws -> AsyncThrowingStream<Data, any Error> {
        let subscription: ChannelSubscription
        switch origin {
        case .adopted:
            guard let adopted = state.withLock({ $0.isCancelled ? nil : $0.subscription }) else {
                throw CancellationError()
            }
            subscription = adopted
        case let .broker(broker, request, slot, expectsRelease):
            if state.withLock({ $0.isCancelled }) { throw CancellationError() }
            if expectsRelease { await broker.expectRelease() }
            do {
                subscription = try await broker.subscribe(request, slot: slot)
            } catch {
                throw Self.playbackError(error)
            }
            let keep = state.withLock { state in
                guard !state.isCancelled else { return false }
                state.subscription = subscription
                return true
            }
            guard keep else {
                // Cancelled while the request was in flight: give the tuner back at once.
                subscription.cancel()
                throw CancellationError()
            }
        }
        return Self.bytes(of: subscription)
    }

    /// The program to select from the PAT, from the open subscription's route: set on a shared multiplex.
    public var programNumber: Int? {
        state.withLock { $0.subscription?.programNumber }
    }

    public func cancel() {
        let subscription = state.withLock { state in
            state.isCancelled = true
            return state.subscription
        }
        subscription?.cancel()
    }

    /// The subscription's data chunks. A broker discontinuity marker (this subscriber fell behind and lost data) has
    /// no byte form; the demuxer notices the continuity-counter gap, and loses sync and finds it again when the gap
    /// splits a packet. The stream pulls straight from the subscription in the reader's own task,
    /// so a chunk costs no extra task hop on its way to the engine.
    private static func bytes(of subscription: ChannelSubscription) -> AsyncThrowingStream<Data, any Error> {
        let reader = SubscriptionReader(subscription)
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }

    /// Device errors stop playback with a message; a broken connection is a network error, which the engine's
    /// watchdog retries; a cancelled or replaced subscription is never retried, so two players can't take turns
    /// stealing the tuner from each other.
    public static func playbackError(_ error: HDHomeRunClientError) -> PlaybackError {
        let kind: PlaybackError.Kind
        switch error {
        case .connectionLost, .unreachable: kind = .network
        case .cancelled: kind = .cancelled
        default: kind = .source
        }
        return PlaybackError(kind: kind, title: error.message, detail: "", domain: "HDHomeRun", code: error.code)
    }
}

/// Reads one subscription's chunks for `ChannelSubscriptionByteSource`, mapping tuner errors to playback errors,
/// and gives the tuner back once nothing reads it any more.
private nonisolated final class SubscriptionReader: @unchecked Sendable {
    // @unchecked: `iterator` is only advanced by the byte stream's single consumer, one call at a time.
    private let subscription: ChannelSubscription
    private var iterator: AsyncThrowingStream<TSChunk, any Error>.Iterator

    init(_ subscription: ChannelSubscription) {
        self.subscription = subscription
        iterator = subscription.chunks.makeAsyncIterator()
    }

    deinit {
        subscription.cancel()
    }

    func next() async throws -> Data? {
        do {
            while let chunk = try await iterator.next() {
                if case .data(let data) = chunk { return data }
            }
            return nil
        } catch let error as HDHomeRunClientError {
            throw ChannelSubscriptionByteSource.playbackError(error)
        }
    }
}

/// A source whose every `open()` fails with one error.
nonisolated struct UnavailableByteSource: ByteSource {
    let error: any Error

    func open() async throws -> AsyncThrowingStream<Data, any Error> {
        throw error
    }

    func cancel() {}
}
