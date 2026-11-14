//
//  ContentViewStartScreen.swift
//  Consolation
//

#if !os(tvOS)
import SwiftUI

struct ContentViewStartScreen: View {
    let capture: CaptureSessionManager
    let showStatusLine: Bool
    @Binding var isShowingAbout: Bool
    @Binding var isShowingHelp: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            startScreenContent
            headerUtilityButtons
                .padding(.trailing, 6)
                .padding(.bottom, 6)
        }
    }

    private var startScreenContent: some View {
        VStack {
            VStack(spacing: 16) {
                header
                StartupDivider()
                statusLine
                mediaPermissionNotice
                deviceControls
                startButton
            }
            .frame(minWidth: 560, maxWidth: 560)
        }
        .frame(minWidth: 560, maxWidth: 560)
    }

    /// The pane's name, like the other panes' titles: no app icon, name or version, which belong to the app.
    private var header: some View {
        Text(ShellItem.captureCard.title)
            .font(.largeTitle.bold())
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private var statusLine: some View {
        if showStatusLine {
            CaptureStatusLine(
                state: capture.state,
                hasUSBVideoCaptureDevice: !capture.usbCaptureDeviceEntries.isEmpty,
                usbVideoCaptureDeviceName: capture.primaryUSBVideoCaptureDisplayName,
                hasAnyVideoDevice: !capture.hasNoVideoDevices,
                statusMessage: capture.statusMessage
            )
        }
    }

    @ViewBuilder
    private var mediaPermissionNotice: some View {
        if capture.mediaPermissionNotice != .none, capture.state != .requestingPermission {
            CaptureMediaPermissionEducationNotice(notice: capture.mediaPermissionNotice)
        }
    }

    @ViewBuilder
    private var deviceControls: some View {
        if !capture.hasNoVideoDevices {
            ContentViewConnectPanel(capture: capture)
        }
    }

    private var startButton: some View {
        Group {
            StartupDivider()
            ContentViewStartWatchingButton(capture: capture)
        }
    }

    private var headerUtilityButtons: some View {
        HStack(spacing: 8) {
            ContentViewHeaderUtilityButton(title: "Help", systemImage: "questionmark.circle") {
                isShowingHelp = true
            }

            ContentViewHeaderUtilityButton(title: "About", systemImage: "info.circle") {
                isShowingAbout = true
            }
        }
    }
}

struct StartupDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.white.opacity(0.42))
    }
}
#endif
