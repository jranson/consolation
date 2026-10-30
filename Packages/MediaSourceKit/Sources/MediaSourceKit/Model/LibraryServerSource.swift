import Foundation

/// A server the user added for its library (Bullpen, Plex): the Library pane lists it by name, and Home asks it
/// to reread its shelves when it appears.
public nonisolated protocol LibraryServerSource: MediaSource {
    var name: String { get }
    /// Reads the server's shelves again and publishes them to `shelfContributions()`.
    func refresh() async
}
