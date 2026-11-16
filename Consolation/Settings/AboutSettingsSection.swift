//
//  AboutSettingsSection.swift
//  Consolation
//
//  Version, links, and the credit and licence for the software decoder library (LGPL-2.1 §6: the notice, the
//  licence text and where to get the library's source), and, where it ships (not Apple TV), YouTubePlayerKit's MIT
//  notice.
//

import PlaybackKit
import SwiftUI

struct AboutSettingsSection: View {
    @State private var showsLicense = false
    @State private var showsEmbedLicense = false

    var body: some View {
        Section {
            LabeledContent("Version", value: BuildInfo.version)
            LabeledContent("Commit", value: BuildInfo.commit)
            Link("Privacy Policy", destination: AppIdentifier.privacyURL)
            Link("Source Code", destination: AppIdentifier.repoURL)
        } header: {
            Text("About")
        }
        Section {
            LabeledContent("Video decoder", value: SoftwareDecoderLibrary.name)
            Text("""
                \(AppIdentifier.name) uses libavcodec and libavutil from FFmpeg, licensed under the GNU Lesser \
                General Public \
                License version 2.1. They are unmodified and dynamically linked, so you can replace them with your \
                own build. FFmpeg is a trademark of Fabrice Bellard.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("FFmpeg Source Code", destination: SoftwareDecoderLibrary.sourceURL)
            Button("GNU Lesser General Public License 2.1") { showsLicense = true }
            #if !os(tvOS)
            Text("""
                YouTube links play in YouTube's own embedded player through YouTubePlayerKit by Sven Tiigi, \
                licensed under the MIT License. YouTube is a trademark of Google LLC.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("YouTubePlayerKit License (MIT)") { showsEmbedLicense = true }
            #endif
        } header: {
            Text("Acknowledgements")
        }
        .sheet(isPresented: $showsLicense) {
            LicenseTextView(title: "LGPL 2.1", text: SoftwareDecoderLibrary.licenseText ?? "")
        }
        #if !os(tvOS)
        .sheet(isPresented: $showsEmbedLicense) {
            LicenseTextView(title: "YouTubePlayerKit (MIT)", text: YouTubeEmbedClient.licenseText)
        }
        #endif
    }
}

private struct LicenseTextView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #if !os(tvOS)
                    .textSelection(.enabled)
                    #endif
            }
            #if os(tvOS)
            // The remote scrolls focusable content only.
            .focusable()
            #endif
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        #endif
    }
}
