//
//  LocalNetworkExplanation.swift
//  Consolation
//
//  The screen `LocalNetworkGate` shows before the system's Local Network prompt.
//

import SwiftUI

extension View {
    /// Shows the Local Network explanation over this view whenever the gate asks for it.
    func localNetworkExplanation(_ gate: LocalNetworkGate) -> some View {
        sheet(isPresented: Binding(get: { gate.isExplaining }, set: { if !$0 { gate.dismiss() } })) {
            LocalNetworkExplanationView(gate: gate)
        }
    }
}

private struct LocalNetworkExplanationView: View {
    let gate: LocalNetworkGate

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Local Network Access", systemImage: "network")
                .font(.title2.weight(.semibold))
            Text("""
                To find and play from your TV tuners and media servers, \(AppIdentifier.name) needs to reach \
                devices on your local network. Next, your device asks whether to allow this.
                """)
            Text("""
                \(AppIdentifier.name) connects only to the tuners, servers and addresses you add or play. It never \
                searches your network on its own, and it never tracks you.
                """)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not Now") { gate.dismiss() }
                Button("Continue") { gate.proceed() }
                    .buttonStyle(.borderedProminent)
                    #if !os(tvOS)
                    .keyboardShortcut(.defaultAction)
                    #endif
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
    }
}
