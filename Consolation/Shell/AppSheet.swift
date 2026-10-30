//
//  AppSheet.swift
//  Consolation
//
//  Sheets the menu bar (and iPad's capture settings menu) opens over the window in front: About and Help.
//

import Foundation

enum AppSheet: String, Identifiable {
    case about
    case help

    var id: String { rawValue }
}
