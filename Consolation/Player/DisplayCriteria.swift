//
//  DisplayCriteria.swift
//  Consolation
//
//  tvOS: asks the TV to switch to the full-screen stream's frame rate (59.94 Hz for deinterlaced 1080i) when the
//  user has turned on Match Content › Frame Rate. Only the full-screen player asks; leaving it hands the display
//  back to the system. Elsewhere this does nothing.
//

import CoreMedia
import PlaybackKit
import SwiftUI
#if os(tvOS)
import AVKit
import UIKit
#endif

/// The display mode a stream would like: its output frame rate and size, standard dynamic range.
nonisolated struct DisplayMatch: Equatable {
    var refreshRate: Float
    var width: Int
    var height: Int

    /// Interlaced pictures play at field rate after deinterlacing, so 29.97 fps 1080i asks for 59.94 Hz.
    init?(info: PlaybackStreamInfo?) {
        guard let info, let rate = info.frameRate, rate > 0, let width = info.width, let height = info.height else {
            return nil
        }
        refreshRate = Float(info.isInterlaced == true && rate < 31 ? rate * 2 : rate)
        self.width = width
        self.height = height
    }

    var formatDescription: CMVideoFormatDescription? {
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        ]
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMPixelFormat_422YpCbCr8, width: Int32(width),
                                       height: Int32(height), extensions: extensions as CFDictionary,
                                       formatDescriptionOut: &description)
        return description
    }
}

extension View {
    /// Requests `match` from the display while this view is on screen (tvOS only).
    func displayCriteria(_ match: DisplayMatch?) -> some View {
        #if os(tvOS)
        background(DisplayCriteriaHost(match: match).allowsHitTesting(false))
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct DisplayCriteriaHost: UIViewRepresentable {
    let match: DisplayMatch?

    func makeUIView(context: Context) -> DisplayCriteriaView {
        DisplayCriteriaView()
    }

    func updateUIView(_ view: DisplayCriteriaView, context: Context) {
        view.match = match
    }

    static func dismantleUIView(_ view: DisplayCriteriaView, coordinator: ()) {
        view.match = nil
    }
}

private final class DisplayCriteriaView: UIView {
    var match: DisplayMatch? {
        didSet { if match != oldValue { apply() } }
    }

    /// Kept so leaving the window can hand the display back.
    private weak var manager: AVDisplayManager?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            manager = window.avDisplayManager
            apply()
        } else {
            manager?.preferredDisplayCriteria = nil
            manager = nil
        }
    }

    private func apply() {
        guard let manager else { return }
        guard let match, let format = match.formatDescription else {
            manager.preferredDisplayCriteria = nil
            return
        }
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: match.refreshRate,
                                                             formatDescription: format)
    }
}
#endif
