//
//  VideoCardInfoView.swift
//  Consolation
//
//  A Home card's "Info" action: what the card is and where it comes from.
//

import MediaSourceKit
import SwiftUI

struct VideoCardInfoView: View {
    let card: VideoCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title).font(.title2.bold())
                if let subtitle = card.subtitle, !subtitle.isEmpty {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Type") { Text(card.kind.title) }
            LabeledContent("Source") { Text(card.playable.item.source.displayName) }
            if card.isHD { LabeledContent("Picture") { Text("HD") } }
            if let percent = card.progressPercent { LabeledContent("Watched") { Text("\(percent)%") } }
            switch card.favorite {
            case .device: Label("Favorite on the HDHomeRun", systemImage: "lock.heart.fill")
            case .app: Label("Favorite", systemImage: "heart.fill")
            case .none: EmptyView()
            }
            Button("Done") { dismiss() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(32)
        .frame(minWidth: 320, maxWidth: 560, alignment: .leading)
    }
}

extension VideoCard.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .liveChannel: "Live channel"
        case .recording: "Recording"
        case .movie: "Movie"
        case .episode: "Episode"
        case .video: "Video"
        case .quickPlay: "Quick Play"
        case .collection: "Collection"
        case .captureCard: "Capture card"
        }
    }
}

extension SourceID {
    /// A source's name for people: "HDHomeRun · Antenna", "Quick Play". Never a host or DeviceID (a `SourceID`
    /// holds neither).
    var displayName: String {
        if let lineupSource = hdhomerunLineupSource { return "HDHomeRun · \(lineupSource)" }
        if self == .quickPlay { return String(localized: "Quick Play") }
        return raw
    }
}
