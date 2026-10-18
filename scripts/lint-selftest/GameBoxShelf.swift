//
//  GameBoxShelf.swift
//  Lint self-test fixture. Never compiled, and outside the paths
//  `make lint` reads. `make lint-selftest` runs SwiftLint on it with the project's config and expects each rule on
//  exactly the lines marked "expect: <rule>": etagere_video_cards_only on every explicit specialization, and
//  etagere_card_conformance on every other card type.
//

import EtagereKit
import SwiftUI

nonisolated struct GameBox: ShelfCardContent {  // expect: etagere_card_conformance
    let id: Int
    let name: String

    var accessibilityTitle: String { name }

    @MainActor
    func makeFace(context: ShelfCardContext) -> some View {
        Text(name)
    }
}

/// A conformance added in an extension is a card type too.
nonisolated struct Cartridge: Identifiable, Hashable, Sendable {
    let id: Int
}

extension Cartridge: ShelfCardContent {}  // expect: etagere_card_conformance

let games = Shelf<GameBox>(id: "games", title: "Games", cards: [])  // expect: etagere_video_cards_only
let arcade = EtagereModel<GameBox>(shelves: [games])  // expect: etagere_video_cards_only
let anchored: ShelfState<GameBox>? = nil  // expect: etagere_video_cards_only

// Inferred generics have no angle brackets, so etagere_video_cards_only can't see them. They need a card type,
// which etagere_card_conformance rejects where it is declared (above).
let inferredShelf = Shelf(id: "games", title: "Games", cards: [GameBox(id: 1, name: "Pong")])
let inferredModel = EtagereModel(shelves: [inferredShelf])

struct GameShelves: View {
    let model: EtagereModel<GameBox>  // expect: etagere_video_cards_only

    var body: some View {
        Etagere<GameBox>(model: model) { _ in } onExit: {}  // expect: etagere_video_cards_only
    }
}

struct InferredGameShelves: View {
    var body: some View {
        Etagere(model: inferredModel) { _ in } onExit: {}
    }
}
