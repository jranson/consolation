//
//  VideoShelfAllowed.swift
//  Lint self-test fixture. Never compiled, and outside the paths
//  `make lint` reads. `make lint-selftest` expects SwiftLint, with the project's config, to pass it: shelves of
//  VideoCard, and other EtagereKit generics, are allowed.
//

import EtagereKit

typealias AllowedShelf = Shelf<VideoCard>
typealias AllowedModel = EtagereModel<VideoCard>
typealias AllowedEtagere = Etagere<VideoCard>
typealias AllowedPosition = EtagerePosition<String>

let channels: Shelf<VideoCard>? = nil
let state: ShelfState<VideoCard>? = nil
