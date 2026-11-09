//
//  LocalFileAccess.swift
//  Consolation
//
//  Reading a local file the user chose. The Mac and iPad apps are sandboxed: they read a file outside their own
//  container only after the user picks it (Choose File…, or a drop), and in a later run only through a bookmark saved
//  while they could read it. A typed `file://` path carries no access. Access, once started, is kept until the app
//  quits, since a playing file is reopened for every seek.
//

import Foundation

nonisolated enum LocalFileAccess {
    /// A file's access restored from its bookmark: where the file is now, and a new bookmark when the saved one is
    /// stale (the file moved or was replaced).
    struct Restored: Sendable {
        let url: URL
        let refreshedBookmark: Data?
    }

    /// Whether the app can read the file now.
    static func isReadable(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false))
    }

    /// Starts access to a URL the user picked or dropped. False for a URL that carries no access of its own.
    @discardableResult
    static func startAccess(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    /// A bookmark that reopens the file in a later run. Made only while the app can read the file; nil otherwise.
    static func bookmark(for url: URL) -> Data? {
        #if os(tvOS)
        return nil
        #else
        guard url.isFileURL else { return nil }
        return try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// Resolves a bookmark and starts access to its file, never mounting a volume or showing UI. Nil when the file
    /// is gone or its volume isn't mounted.
    static func restore(_ bookmark: Data) -> Restored? {
        #if os(tvOS)
        return nil
        #else
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: resolutionOptions, relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        startAccess(url)
        return Restored(url: url, refreshedBookmark: isStale ? self.bookmark(for: url) : nil)
        #endif
    }

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [
        .withSecurityScope, .securityScopeAllowOnlyReadAccess
    ]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [
        .withSecurityScope, .withoutUI, .withoutMounting
    ]
    #elseif !os(tvOS)
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
    #endif
}
