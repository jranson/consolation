//
//  CornerPill.swift
//  Consolation
//
//  The upper right's Liquid Glass capsule: Apple TV's time while the menu is open, and a run of left and right jumps
//  in the player on every platform. Never focusable.
//

import SwiftUI

struct CornerPill: View {
    let text: Text
    let identifier: String

    var body: some View {
        text
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(false)
    }
}

/// A run of jumps ("+20s"), counting as it changes.
struct JumpPill: View {
    let jump: PlaybackJump

    var body: some View {
        CornerPill(text: Text(jump.label), identifier: "player.jump")
            .contentTransition(.numericText(value: jump.total))
            .animation(.smooth(duration: 0.2), value: jump.total)
    }
}
