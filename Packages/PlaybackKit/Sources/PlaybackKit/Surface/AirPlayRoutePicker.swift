//
//  AirPlayRoutePicker.swift
//  PlaybackKit
//
//  The system AirPlay button for AVPlayerEngine content. Only AVPlayer can send video over AirPlay; the MPEG-TS
//  engine renders sample buffers itself, so hosts show this for `AVPlayerEngine` only.
//

import AVFoundation
import AVKit
import SwiftUI

public struct AirPlayRoutePicker: View {
    private let engine: AVPlayerEngine

    public init(engine: AVPlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        RoutePickerRepresentable(player: engine.player)
            .frame(width: 36, height: 36)
            .accessibilityLabel(Text("AirPlay"))
    }
}

#if os(macOS)
private struct RoutePickerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player
    }
}
#else
private struct RoutePickerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        #if os(iOS)
        view.tintColor = .label
        #endif
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
