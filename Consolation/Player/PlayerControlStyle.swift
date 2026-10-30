//
//  PlayerControlStyle.swift
//  Consolation
//
//  How the controls' buttons look: an icon, and on Apple TV a white circle just around it while it has focus (the
//  system's focus platter was wider than the button and ran into its neighbours, and the More menu drew a platter of
//  its own).
//

import SwiftUI

enum PlayerControlMetrics {
    #if os(tvOS)
    static let iconSize: CGFloat = 26
    static let buttonSize: CGFloat = 56
    static let spacing: CGFloat = 10
    #else
    static let iconSize: CGFloat = 20
    static let buttonSize: CGFloat = 36
    static let spacing: CGFloat = 18
    #endif
}

/// The icon a control button or menu shows.
struct PlayerControlIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: PlayerControlMetrics.iconSize, weight: .semibold))
            .frame(width: PlayerControlMetrics.buttonSize, height: PlayerControlMetrics.buttonSize)
            .contentShape(Circle())
    }
}

/// No platter: the icon alone, with a white circle behind it (and the icon turned dark) while focused.
struct PlayerControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayerControlButtonBody(configuration: configuration)
    }
}

private struct PlayerControlButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background {
                if isFocused { Circle().fill(.white) }
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.smooth(duration: 0.15), value: isFocused)
    }
}

extension View {
    /// The controls' look: `PlayerControlButtonStyle` without the system's focus effect.
    func playerControlStyle() -> some View {
        buttonStyle(PlayerControlButtonStyle())
            .focusEffectDisabled()
    }
}
