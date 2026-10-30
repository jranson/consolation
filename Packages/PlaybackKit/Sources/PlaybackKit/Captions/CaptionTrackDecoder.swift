//
//  CaptionTrackDecoder.swift
//  PlaybackKit
//
//  The caption pipeline for one video stream: reorders each picture's A/53 `cc_data` into presentation order and
//  decodes all four CEA-608 services, reporting changes to the selected one.
//

import Foundation

nonisolated public struct CaptionTrackDecoder: Sendable {
    /// The selected service's screen as of a presentation time (90 kHz).
    public struct Update: Sendable, Equatable {
        public var pts: Int64
        public var screen: CaptionScreen

        public init(pts: Int64, screen: CaptionScreen) {
            self.pts = pts
            self.screen = screen
        }
    }

    public private(set) var service: CaptionService
    /// Services that have displayed a caption since the last reset, for a Subtitles menu.
    public private(set) var servicesWithCaptions: Set<CaptionService> = []
    private var reorderer: CaptionCCDataReorderer
    private var decoders: [CEA608Decoder]

    public init(
        service: CaptionService = .cc1,
        reorderWindow: Int = 4,
        staleTimeout: Int64 = CEA608Decoder.defaultStaleTimeout
    ) {
        self.service = service
        reorderer = CaptionCCDataReorderer(window: reorderWindow)
        decoders = CaptionService.allCases.map { CEA608Decoder(service: $0, staleTimeout: staleTimeout) }
    }

    /// The selected service's current screen.
    public var screen: CaptionScreen { decoders[index(of: service)].screen }

    /// Switches to another service and returns its current screen (every service is decoded all along, so a
    /// caption already on that service shows at once).
    @discardableResult
    public mutating func select(_ service: CaptionService) -> CaptionScreen {
        self.service = service
        return screen
    }

    /// Feeds one picture in decode order. Returns the selected service's latest screen if it changed while the
    /// pictures released by the reorder window were decoded, otherwise nil.
    public mutating func feed(pts: Int64, captionData: Data?) -> CaptionScreen? {
        feedUpdates(pts: pts, captionData: captionData).last?.screen
    }

    /// Feeds one picture in decode order and returns every change to the selected service, each stamped with the
    /// presentation time it takes effect.
    public mutating func feedUpdates(pts: Int64, captionData: Data?) -> [Update] {
        decode(reorderer.push(pts: pts, data: captionData ?? Data()))
    }

    /// Decodes the pictures still held in the reorder window (end of stream).
    public mutating func flush() -> [Update] {
        decode(reorderer.flush())
    }

    /// Drops held pictures and all caption state, as after a discontinuity or retune. The selection is kept.
    public mutating func reset() {
        reorderer.reset()
        for index in decoders.indices {
            decoders[index].reset()
        }
        servicesWithCaptions.removeAll()
    }

    private func index(of service: CaptionService) -> Int {
        service.rawValue - 1
    }

    private mutating func decode(_ entries: [CaptionCCDataReorderer.Entry]) -> [Update] {
        var updates: [Update] = []
        let selected = index(of: service)
        for entry in entries {
            for index in decoders.indices {
                guard decoders[index].decode(ccData: entry.data, pts: entry.pts) else { continue }
                let screen = decoders[index].screen
                if !screen.isEmpty {
                    servicesWithCaptions.insert(decoders[index].service)
                }
                if index == selected {
                    updates.append(Update(pts: entry.pts, screen: screen))
                }
            }
        }
        return updates
    }
}
