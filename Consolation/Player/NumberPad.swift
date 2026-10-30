//
//  NumberPad.swift
//  Consolation
//
//  tvOS: channel-number entry for the remote's 123 button. Digits and "." build a guide number; Go tunes it.
//

import SwiftUI

struct NumberPad: View {
    @Environment(PlayerSession.self) private var session
    @FocusState private var focusedKey: String?

    private static let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "⌫"]]

    var body: some View {
        VStack(spacing: 14) {
            Text(session.enteredDigits.isEmpty ? " " : session.enteredDigits)
                .font(.system(size: 52, weight: .bold).monospacedDigit())
                .frame(minWidth: 220)
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 14) {
                    ForEach(row, id: \.self) { key in
                        Button { press(key) } label: {
                            Text(key)
                                .font(.title2.bold())
                                .frame(width: 72, height: 56)
                        }
                        .focused($focusedKey, equals: key)
                        .accessibilityLabel(key == "⌫" ? "Delete" : key)
                    }
                }
            }
            HStack(spacing: 14) {
                Button("Cancel", role: .cancel) { close() }
                Button("Go") {
                    session.commitDigits()
                    close()
                }
                .disabled(session.enteredDigits.isEmpty)
            }
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .onAppear { focusedKey = "1" }
        .onExitCommandIfAvailable { close() }
    }

    private func press(_ key: String) {
        if key == "⌫" {
            session.deleteDigit()
        } else if let character = key.first {
            session.enterDigit(character)
        }
    }

    private func close() {
        while !session.enteredDigits.isEmpty { session.deleteDigit() }
        session.numberPadVisible = false
    }
}

private extension View {
    func onExitCommandIfAvailable(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS) || os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}
