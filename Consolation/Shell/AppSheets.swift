//
//  AppSheets.swift
//  Consolation
//
//  Presents the menu bar's About and Help sheets over one window (`ShellModel.presentedSheet`).
//

#if !os(tvOS)
import SwiftUI

extension View {
    func appSheets(shell: ShellModel) -> some View {
        modifier(AppSheetsModifier(shell: shell))
    }
}

private struct AppSheetsModifier: ViewModifier {
    @Bindable var shell: ShellModel

    func body(content: Content) -> some View {
        content.sheet(item: $shell.presentedSheet) { sheet in
            Group {
                switch sheet {
                case .about: AboutConsolationView { shell.presentedSheet = nil }
                case .help: HelpConsolationView { shell.presentedSheet = nil }
                }
            }
            #if os(macOS)
            .interactiveDismissDisabled()
            #endif
        }
    }
}
#endif
