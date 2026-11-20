import Foundation

/// A server the user added for its library (Bullpen, Plex): the Library pane lists it by name, and Home asks it
/// to reread its shelves when it appears.
public nonisolated protocol LibraryServerSource: MediaSource {
    var name: String { get }
    /// Reads the server's shelves again and publishes them to `shelfContributions()`.
    func refresh() async
    /// The suspected commercial breaks in an item the server found them in (a recording), for "Skip Commercials".
    /// Asks the server; `.none` for an item it has no breaks for.
    func adBreaks(for itemID: MediaItemID) async throws -> AdBreakList
}

public extension LibraryServerSource {
    /// Servers that don't detect commercial breaks have none.
    func adBreaks(for itemID: MediaItemID) async throws -> AdBreakList { .none }
}
