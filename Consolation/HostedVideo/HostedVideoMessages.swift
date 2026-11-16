//
//  HostedVideoMessages.swift
//  Consolation
//
//  Apple TV: why a YouTube video couldn't go to the YouTube app. Mac, iPad and iPhone play it in the embed and never
//  set the message.
//

import SwiftUI

extension View {
    func hostedVideoMessages(_ player: HostedVideoPlayer) -> some View {
        alert("Can't Play This Video",
              isPresented: Binding(get: { player.handOffFailure != nil },
                                   set: { if !$0 { player.handOffFailure = nil } })) {
            Button("OK", role: .cancel) { player.handOffFailure = nil }
        } message: {
            Text(player.handOffFailure ?? "")
        }
    }
}
