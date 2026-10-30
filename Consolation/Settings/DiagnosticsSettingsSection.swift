//
//  DiagnosticsSettingsSection.swift
//  Consolation
//
//  What this device can decode, and the software decoder library's version and build configuration. Everything
//  shown is read from the device itself; nothing is sent anywhere.
//

import PlaybackKit
import SwiftUI

struct DiagnosticsSettingsSection: View {
    @State private var results: [DecoderProbeResult] = []
    @State private var showsConfiguration = false

    var body: some View {
        Section {
            if results.isEmpty {
                ProgressView()
            }
            ForEach(results) { result in
                LabeledContent {
                    Text(result.status.label)
                        .foregroundStyle(result.status == .unavailable ? .secondary : .primary)
                } label: {
                    Text(result.name)
                    if !result.detail.isEmpty {
                        Text(result.detail)
                    }
                }
            }
            LabeledContent("libavcodec", value: SoftwareDecoderLibrary.codecVersion)
            Button(showsConfiguration ? "Hide Build Configuration" : "Show Build Configuration") {
                showsConfiguration.toggle()
            }
            if showsConfiguration {
                Text(SoftwareDecoderLibrary.configuration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if Clipboard.isAvailable {
                Button("Copy Diagnostics") { Clipboard.copy(report) }
                    .disabled(results.isEmpty)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Read from this device only. Copy Diagnostics puts the list on the clipboard for a bug report.")
        }
        .task { results = await DecoderProbe.run() }
    }

    private var report: String {
        var lines = results.map { result in
            "\(result.name): \(result.status.label)" + (result.detail.isEmpty ? "" : " (\(result.detail))")
        }
        lines.append("libavcodec \(SoftwareDecoderLibrary.codecVersion): \(SoftwareDecoderLibrary.configuration)")
        lines.append(BuildInfo.copyableBlob)
        return lines.joined(separator: "\n")
    }
}

private extension DecoderProbeResult.Status {
    var label: String {
        switch self {
        case .hardware: String(localized: "Hardware")
        case .software: String(localized: "Software")
        case .unavailable: String(localized: "Not available")
        }
    }
}
