//
//  DocumentStore.swift
//  Consolation
//
//  Where the app keeps its small Codable documents (sources, favorites, Quick Play history), per platform:
//  JSON files in Application Support on macOS and iOS, compact UserDefaults entries on tvOS (whose apps get only
//  about 500 KB of persistent storage). Settings stay in UserDefaults everywhere.
//

import Foundation
import OSLog

protocol DocumentStore: AnyObject {
    func data(named name: String) -> Data?
    func setData(_ data: Data?, named name: String)
}

extension DocumentStore {
    func load<Value: Decodable>(_ type: Value.Type, named name: String) -> Value? {
        guard let data = data(named: name) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Saves `value`, or removes the document when `value` is nil.
    func save(_ value: (some Encodable)?, named name: String) {
        setData(value.flatMap { try? JSONEncoder().encode($0) }, named: name)
    }

    /// Moves a document saved by an earlier build in a UserDefaults key into this store, once.
    func migrate(named name: String, fromDefaultsKey key: String, in defaults: UserDefaults,
                 encode: (Any) -> Data?) {
        guard data(named: name) == nil, let legacy = defaults.object(forKey: key) else { return }
        if let data = encode(legacy) { setData(data, named: name) }
        defaults.removeObject(forKey: key)
    }
}

enum DocumentStores {
    /// The store for this platform.
    static func platformDefault() -> any DocumentStore {
        #if os(tvOS)
        DefaultsDocumentStore(defaults: .standard)
        #else
        FileDocumentStore(directory: FileDocumentStore.applicationSupportDirectory)
        #endif
    }
}

/// One JSON file per document, written atomically.
final class FileDocumentStore: DocumentStore {
    private static let logger = Logger(subsystem: AppIdentifier.bundleID, category: "Storage")
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Application Support/<bundle ID> (inside the sandbox container on macOS).
    static var applicationSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: AppIdentifier.bundleID, directoryHint: .isDirectory)
    }

    private func fileURL(_ name: String) -> URL {
        directory.appending(path: "\(name).json", directoryHint: .notDirectory)
    }

    func data(named name: String) -> Data? {
        try? Data(contentsOf: fileURL(name))
    }

    func setData(_ data: Data?, named name: String) {
        let url = fileURL(name)
        do {
            guard let data else {
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            let reason = error.localizedDescription
            Self.logger.error("Couldn't save \(name, privacy: .public): \(reason, privacy: .public)")
        }
    }
}

/// tvOS: documents as Data values under namespaced UserDefaults keys. Also the in-memory store for tests, with a
/// throwaway suite.
final class DefaultsDocumentStore: DocumentStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func key(_ name: String) -> String { AppIdentifier.scoped("documents.\(name)") }

    func data(named name: String) -> Data? {
        defaults.data(forKey: key(name))
    }

    func setData(_ data: Data?, named name: String) {
        if let data {
            defaults.set(data, forKey: key(name))
        } else {
            defaults.removeObject(forKey: key(name))
        }
    }
}
