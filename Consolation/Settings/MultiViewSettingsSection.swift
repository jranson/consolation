//
//  MultiViewSettingsSection.swift
//  Consolation
//
//  Settings › Multi-view: how many tuners multi-view leaves for the rest of the household, whether the grid's sound
//  follows focus, and when channels may share a tuner's multiplex.
//

import SwiftUI

struct MultiViewSettingsSection: View {
    @Environment(PlaybackPreferences.self) private var preferences

    var body: some View {
        @Bindable var prefs = preferences
        Section {
            ValueStepper(title: "Keep tuners free for others", value: $prefs.tunerReserve,
                         range: PlaybackPreferences.tunerReserveRange) { "\($0)" }
            Toggle("Audio follows focus", isOn: $prefs.audioFollowsFocus)
            Picker("Share a tuner between channels", selection: $prefs.multiplexSharing) {
                Text("Never").tag(PlaybackPreferences.MultiplexSharing.never)
                Text("When tuners are short").tag(PlaybackPreferences.MultiplexSharing.whenTunersAreShort)
                Text("Always").tag(PlaybackPreferences.MultiplexSharing.always)
            }
        } header: {
            Text("Multi-view")
        } footer: {
            Text(footer)
        }
        Section {
            Toggle("Show ATSC 3.0 channels", isOn: $prefs.showsATSC3Channels)
        } header: {
            Text("Live TV")
        } footer: {
            Text("""
                ATSC 3.0 channels play without sound: their AC-4 audio can't be decoded on Apple devices. Channels \
                protected with DRM are listed but can't play. Live TV offers each one's ATSC 1.0 channel, with sound, \
                when it finds one.
                """)
        }
    }

    private var footer: String {
        var text = """
            Multi-view tiles leave this many tuners free for other TVs and recordings; the channel you start \
            yourself always plays. Channels broadcast together on one frequency can share a single tuner.
            """
        if preferences.tunerReserve == 0 {
            text += " With none kept free, scheduled recordings on other devices may fail while multi-view runs."
        }
        return text
    }
}
