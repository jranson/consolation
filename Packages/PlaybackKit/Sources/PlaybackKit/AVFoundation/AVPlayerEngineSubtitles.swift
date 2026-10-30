//
//  AVPlayerEngineSubtitles.swift
//  PlaybackKit
//
//  Subtitles and captions for AVPlayer content: the asset's legible media selection group (HLS SUBTITLES and
//  CLOSED-CAPTIONS renditions, WebVTT, embedded CEA-608). AVPlayerLayer draws them, styled by MediaAccessibility.
//

import AVFoundation

extension AVPlayerEngine: SubtitleSelecting {
    public func selectSubtitle(id: String?) {
        guard let item = player.currentItem, let group = legibleGroup else { return }
        let option = id.flatMap { wanted in
            group.options.enumerated().first { Self.subtitleID($0.offset, $0.element) == wanted }?.element
        }
        // Turning subtitles off must also stop forced-only and automatic selection from bringing them back.
        player.appliesMediaSelectionCriteriaAutomatically = false
        item.select(option, in: group)
        selectedSubtitleID = option == nil ? nil : id
    }

    /// Loads the legible renditions once the item is ready, and notes which one AVPlayer chose automatically
    /// (from the user's system caption preferences).
    func loadSubtitleOptions(token: Int) async {
        guard isCurrent(token), let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), isCurrent(token) else {
            return
        }
        legibleGroup = group
        let options = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        subtitleOptions = options.map { option in
            let index = group.options.firstIndex(of: option) ?? 0
            return SubtitleOption(id: Self.subtitleID(index, option), displayName: option.displayName,
                                  isClosedCaptions: option.mediaType == .closedCaption
                                      || option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility))
        }
        if let current = item.currentMediaSelection.selectedMediaOption(in: group),
           !current.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
           let index = group.options.firstIndex(of: current) {
            selectedSubtitleID = Self.subtitleID(index, current)
        }
    }

    /// Stable for the item's life: the rendition's position plus its language, e.g. "2:en".
    nonisolated static func subtitleID(_ index: Int, _ option: AVMediaSelectionOption) -> String {
        "\(index):\(option.extendedLanguageTag ?? option.locale?.identifier ?? "und")"
    }
}
