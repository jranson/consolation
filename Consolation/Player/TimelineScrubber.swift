//
//  TimelineScrubber.swift
//  Consolation
//
//  The timeline: a track filled up to the position, with a dot the user moves to a new point before committing it.
//  Apple TV: focus the timeline, left and right move the dot (in steps that grow while the presses come quickly), a
//  swipe slides it, and a touch held on the clickpad's outer ring then swirled around it fine-tunes it (the ring jog,
//  RingJog.swift); Select jumps there, Back puts the dot back. Mac, iPad and iPhone: drag the dot (or click or tap the
//  track) and release to jump there.
//

import PlaybackKit
import SwiftUI

struct TimelineScrubber: View {
    let timeline: PlaybackTimeline
    /// The point the dot was moved to, not yet committed.
    @Binding var pending: Double?
    let onCommit: (Double) -> Void
    /// The user is working the scrubber (keeps the controls up).
    var onActivity: () -> Void = {}

    @FocusState private var isFocused: Bool
    @Environment(PlayerSession.self) private var session
    @State private var stepper = ScrubStepper()
    /// Apple TV: where the dot was when the current swipe began.
    @State private var swipeStart: Double?
    /// Apple TV: a swipe is in progress (no ring jog begins during one).
    @State private var isSwiping = false
    /// Apple TV: the ring jog is moving the dot (its icon shows on the dot).
    @State private var isJogging = false
    /// Apple TV: the current swipe came with a jog, so it never moves the dot; the next swipe does again.
    @State private var swipeHeldByJog = false
    /// The point just committed, shown until playback reports it (engines can report the old position for a moment
    /// while a seek lands, which would make the dot spring back).
    @State private var committed: (position: Double, at: ContinuousClock.Instant)?

    /// How long a committed point is held at most, and how close playback must come to release it early.
    static let holdLimit: Duration = .seconds(5)
    static let holdTolerance = 2.0
    /// Apple TV: a swipe starting this soon after a commit is the touch of the Select press, not a new scrub.
    static let swipeQuietAfterCommit: Duration = .milliseconds(500)

    /// The committed point while playback hasn't caught up with it yet.
    private var heldPosition: Double? {
        guard let committed, ContinuousClock.now - committed.at < Self.holdLimit,
              abs(timeline.position - committed.position) > Self.holdTolerance else { return nil }
        return committed.position
    }

    /// Apple TV: a swipe across the whole touch surface (about the screen's width in points) moves the dot by the
    /// whole timeline, at most 30 minutes, so long recordings stay controllable; repeated swipes go further.
    static func secondsPerSwipePoint(duration: Double) -> Double {
        min(duration, 1_800) / 1_920
    }

    var body: some View {
        track
            .frame(height: Self.touchHeight)
            .accessibilityElement()
            .accessibilityLabel("Timeline")
            .accessibilityValue(TimeLabel.text(timeline.elapsed(at: pending)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: commit(step(1))
                case .decrement: commit(step(-1))
                @unknown default: break
                }
            }
            .accessibilityIdentifier("player.timeline")
            .onAppear(perform: takeRequestedFocus)
            .onChange(of: session.timelineFocusRequested) { takeRequestedFocus() }
            .modifier(input)
    }

    #if os(tvOS)
    static let touchHeight: CGFloat = 40
    #else
    static let touchHeight: CGFloat = 22
    #endif

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let shown = pending ?? heldPosition ?? timeline.position
            let fraction = fraction(of: shown)
            let trackHeight: CGFloat = isFocused ? 10 : 6
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: trackHeight)
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: max(width * self.fraction(of: heldPosition ?? timeline.position), trackHeight),
                           height: trackHeight)
                if pending != nil {
                    // Where playback is now, while the dot shows where it will go.
                    Capsule().fill(.white).frame(width: 3, height: trackHeight + 8)
                        .offset(x: width * timeline.fraction - 1.5)
                }
                Circle()
                    .fill(.white)
                    .frame(width: dotSize, height: dotSize)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .overlay {
                        if isJogging {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                                .font(.system(size: dotSize * 0.5, weight: .bold))
                                .foregroundStyle(.black)
                                .accessibilityHidden(true)
                        }
                    }
                    .offset(x: width * fraction - dotSize / 2)
                if let pending {
                    Text(TimeLabel.text(timeline.elapsed(at: pending)))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: .capsule)
                        .fixedSize()
                        .offset(x: min(max(width * fraction - 24, 0), max(width - 56, 0)), y: -26)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    pending = timeline.position(atFraction: value.location.x / max(width, 1))
                    onActivity()
                }
                .onEnded { value in
                    commit(timeline.position(atFraction: value.location.x / max(width, 1)))
                })
            #endif
        }
    }

    private var dotSize: CGFloat {
        #if os(tvOS)
        isJogging ? 36 : isFocused ? 28 : 16
        #else
        pending != nil ? 18 : 14
        #endif
    }

    private func fraction(of position: Double) -> Double {
        timeline.duration > 0 ? (position - timeline.range.lowerBound) / timeline.duration : 1
    }

    /// The pending point moved by one step (growing with quick presses) in `direction` (+1 forward, −1 back).
    private func step(_ direction: Double) -> Double {
        let start = pending ?? heldPosition ?? timeline.position
        let seconds = stepper.next(duration: timeline.duration)
        return clamped(start + direction * seconds)
    }

    private func clamped(_ position: Double) -> Double {
        min(max(position, timeline.range.lowerBound), timeline.range.upperBound)
    }

    /// Apple TV's Play/Pause asked for the timeline: take focus once on screen. When the controls were hidden, the
    /// timeline appears with them and the focus engine may not accept it yet (focus would land on the buttons), so it
    /// asks again for a moment until it has it.
    private func takeRequestedFocus() {
        guard session.timelineFocusRequested else { return }
        session.timelineFocusRequested = false
        Task { @MainActor in
            for _ in 0..<Self.focusAttempts {
                isFocused = true
                try? await Task.sleep(for: .milliseconds(80))
                if isFocused { return }
            }
        }
    }

    /// How many times (80 ms apart) the timeline asks for focus after Play/Pause.
    static let focusAttempts = 8

    private func commit(_ position: Double) {
        pending = nil
        swipeStart = nil
        isJogging = false
        committed = (position, .now)
        stepper.reset()
        onCommit(position)
    }

    private var input: some ViewModifier {
        #if os(tvOS)
        RemoteScrubInput(isFocused: $isFocused, isScrubbing: pending != nil, isJogging: isJogging,
                         canJog: !isSwiping, onMove: { direction in
            pending = step(direction)
            onActivity()
        }, onSelect: {
            if let pending { commit(pending) }
        }, onCancel: cancel, onFocusLost: focusLost, onPan: panned, onJog: jogged)
        #else
        EmptyModifier()
        #endif
    }

    #if os(tvOS)
    /// Back: the dot goes back to playback's position (and a jog in progress stops moving it).
    private func cancel() {
        pending = nil
        isJogging = false
        stepper.reset()
    }

    /// A jog keeps the timeline focused: swirling around the ring also reads as swipes up and down to the focus
    /// engine, which would otherwise carry focus off to the buttons.
    private func focusLost() {
        if isJogging {
            if RingJogTrace.isOn { print("Timeline jog kept focus") }
            isFocused = true
            return
        }
        isSwiping = false
        cancel()
    }

    private func panned(_ phase: RemotePanPhase, _ travel: CGFloat) {
        switch phase {
        case .ended:
            isSwiping = false
            return
        case .began:
            isSwiping = true
            if !isJogging { swipeHeldByJog = false }
        case .changed:
            break
        }
        if isJogging || swipeHeldByJog { return }
        if let committed, ContinuousClock.now - committed.at < Self.swipeQuietAfterCommit { return }
        if phase == .began || swipeStart == nil { swipeStart = pending ?? heldPosition ?? timeline.position }
        guard let swipeStart else { return }
        pending = clamped(swipeStart + Double(travel) * Self.secondsPerSwipePoint(duration: timeline.duration))
        onActivity()
    }

    private func jogged(_ event: RingJog.Event) {
        switch event {
        case .began:
            isJogging = true
            swipeHeldByJog = true
            swipeStart = nil
            pending = pending ?? heldPosition ?? timeline.position
        case .moved(let seconds):
            guard isJogging else { return }
            pending = clamped((pending ?? heldPosition ?? timeline.position) + seconds)
        case .ended:
            isJogging = false
            return
        }
        onActivity()
    }
    #endif
}

#if os(tvOS)
/// The Siri Remote on the focused timeline: a button (so Select arrives as its primary action), left and right to
/// move the dot, Back to put it back while scrubbing (otherwise Back goes on to hide the controls).
private struct RemoteScrubInput: ViewModifier {
    let isFocused: FocusState<Bool>.Binding
    let isScrubbing: Bool
    let isJogging: Bool
    /// No ring jog may begin (a swipe is in progress).
    let canJog: Bool
    let onMove: (Double) -> Void
    let onSelect: () -> Void
    let onCancel: () -> Void
    let onFocusLost: () -> Void
    /// A horizontal swipe on the touch surface: where it is, and its travel so far.
    let onPan: (RemotePanPhase, CGFloat) -> Void
    /// The ring jog (RemoteRingJog.swift).
    let onJog: (RingJog.Event) -> Void

    func body(content: Content) -> some View {
        Button(action: onSelect) { content }
            .buttonStyle(ScrubberButtonStyle())
            .focusEffectDisabled()
            .focused(isFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left: onMove(-1)
                case .right: onMove(1)
                default: break
                }
            }
            .onExitCommand(perform: isScrubbing ? onCancel : nil)
            .remoteHorizontalPan(isEnabled: isFocused.wrappedValue, onPan: onPan)
            .remoteRingJog(isEnabled: isFocused.wrappedValue || isJogging, canBegin: canJog, onJog: onJog)
            .onChange(of: isFocused.wrappedValue) { _, focused in
                if !focused { onFocusLost() }
            }
    }
}

private struct ScrubberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
#endif

/// Step sizes for remote presses: a base step from the timeline's length, doubling while presses come within
/// `streakWindow` of each other, up to eight times the base.
struct ScrubStepper {
    static let streakWindow: Duration = .milliseconds(450)
    static let maxMultiplier = 8.0

    private var lastStep: ContinuousClock.Instant?
    private var multiplier = 1.0

    /// 10 s for short ranges, about 1% of longer ones, never more than 60 s.
    static func baseStep(duration: Double) -> Double {
        min(max(duration / 100, 10), 60)
    }

    mutating func next(duration: Double, now: ContinuousClock.Instant = .now) -> Double {
        if let lastStep, now - lastStep <= Self.streakWindow {
            multiplier = min(multiplier * 2, Self.maxMultiplier)
        } else {
            multiplier = 1
        }
        lastStep = now
        return Self.baseStep(duration: duration) * multiplier
    }

    mutating func reset() {
        lastStep = nil
        multiplier = 1
    }
}
