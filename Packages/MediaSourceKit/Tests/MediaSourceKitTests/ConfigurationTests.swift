import Foundation
import Testing
@testable import MediaSourceKit

/// Source configurations are Codable, never hold secrets, and reach storage only through injected stores.
@Suite("SourceConfiguration", .timeLimit(.minutes(1)))
struct ConfigurationTests {
    static let antenna = SourceConfiguration(
        id: .hdhomerunLive(lineupSource: "Antenna"), kind: .hdhomerun, displayName: "Antenna",
        endpoints: ["hdhomerun.local", "192.0.2.10"], options: ["lineupSource": "Antenna"])

    @Test func configurationsRoundTrip() throws {
        let plex = SourceConfiguration(
            id: SourceID(raw: "plex:0f0e"), kind: .plex, displayName: "Media Server",
            endpoints: ["http://192.0.2.30:32400"],
            pathMappings: [PathMapping(serverPrefix: "/Volumes/Media",
                                       target: .folder(SourceID(raw: "folder:1"), relativePath: "DVR"))],
            bookmark: Data([1, 2, 3]), isEnabled: false)
        for configuration in [Self.antenna, plex] {
            let data = try JSONEncoder().encode(configuration)
            #expect(try JSONDecoder().decode(SourceConfiguration.self, from: data) == configuration)
        }
    }

    @Test func secretsAreRejected() throws {
        try Self.antenna.validateNoSecrets()
        var withToken = Self.antenna
        withToken.endpoints = ["http://192.0.2.30:32400/?X-Plex-Token=abc"]
        #expect(throws: SourceConfigurationError.containsSecret(field: "endpoints[0]")) {
            try withToken.validateNoSecrets()
        }
        var withPassword = Self.antenna
        withPassword.endpoints = ["hdhomerun.local", "smb://user:pw@192.0.2.40/share"]
        #expect(throws: SourceConfigurationError.containsSecret(field: "endpoints[1]")) {
            try withPassword.validateNoSecrets()
        }
        var withOption = Self.antenna
        withOption.options["accessToken"] = "abc"
        #expect(throws: SourceConfigurationError.containsSecret(field: "options.accessToken")) {
            try withOption.validateNoSecrets()
        }
        #expect(SourceConfiguration.isSecretName("api_key"))
        #expect(!SourceConfiguration.isSecretName("lineupSource"))
    }

    @Test func storesRefuseToSaveSecrets() async throws {
        let store = InMemorySourceConfigurationStore()
        var leaky = Self.antenna
        leaky.options["password"] = "pw"
        await #expect(throws: SourceConfigurationError.self) { try await store.upsert(leaky) }
        #expect(await store.loadConfigurations().isEmpty)
    }

    @Test func keyValueStoreKeepsConfigurationsUnderTheInjectedKey() async throws {
        let values = InMemoryKeyValueStore()
        let store = KeyValueSourceConfigurationStore(store: values, key: "test.sources")
        #expect(try await store.loadConfigurations().isEmpty)

        try await store.upsert(Self.antenna)
        var renamed = Self.antenna
        renamed.displayName = "Roof antenna"
        try await store.upsert(renamed)
        #expect(try await store.loadConfigurations() == [renamed])
        #expect(await values.keys == ["test.sources"])

        try await store.remove(Self.antenna.id)
        #expect(try await store.loadConfigurations().isEmpty)
        #expect(await values.keys.isEmpty)
    }

    static func folder(_ number: Int) -> SourceConfiguration {
        SourceConfiguration(id: SourceID(raw: "folder:\(number)"), kind: .folder, displayName: "Folder \(number)")
    }

    @Test func concurrentEditsNeverLoseOneAnother() async throws {
        let values = SuspendingKeyValueStore()
        let stores: [any SourceConfigurationStore] = [
            KeyValueSourceConfigurationStore(store: values, key: "test.sources"),
            InMemorySourceConfigurationStore()
        ]
        for store in stores {
            await withThrowingTaskGroup(of: Void.self) { group in
                for number in 1...8 {
                    group.addTask { try await store.upsert(Self.folder(number)) }
                }
            }
            let saved = try await store.loadConfigurations().map(\.id.raw).sorted()
            #expect(saved == (1...8).map { "folder:\($0)" }.sorted())

            await withThrowingTaskGroup(of: Void.self) { group in
                for number in [2, 4, 6] {
                    group.addTask { try await store.remove(SourceID(raw: "folder:\(number)")) }
                }
                group.addTask { try await store.upsert(Self.folder(9)) }
            }
            let remaining = try await store.loadConfigurations().map(\.id.raw).sorted()
            #expect(remaining == [1, 3, 5, 7, 8, 9].map { "folder:\($0)" }.sorted())
        }
    }

    @Test func unchangedUpdatesWriteNothing() async throws {
        let values = SuspendingKeyValueStore()
        let store = KeyValueSourceConfigurationStore(store: values, key: "test.sources")
        try await store.upsert(Self.antenna)
        #expect(await values.writeCount == 1)
        try await store.upsert(Self.antenna)
        try await store.remove(SourceID(raw: "folder:404"))
        #expect(await values.writeCount == 1)
        var leaky = Self.antenna
        leaky.options["apiKey"] = "zz"
        await #expect(throws: SourceConfigurationError.self) { try await store.upsert(leaky) }
        #expect(try await store.loadConfigurations() == [Self.antenna])
    }

    @Test func pathMappingsPickTheLongestWholeComponentPrefix() throws {
        let folder = SourceID(raw: "folder:1")
        let media = PathMapping(serverPrefix: "/Volumes/Media", target: .folder(folder, relativePath: ""))
        let dvr = PathMapping(serverPrefix: "/Volumes/Media/DVR/",
                              target: .smb(SourceID(raw: "smb:2"), share: "DVR", path: ""))
        let match = try #require(PathMapping.bestMatch(for: "/Volumes/Media/DVR/Show/ep.ts", in: [media, dvr]))
        #expect(match.mapping == dvr)
        #expect(match.remainder == "Show/ep.ts")
        #expect(PathMapping.bestMatch(for: "/Volumes/Media/Movies/a.mp4", in: [media, dvr])?.mapping == media)
        #expect(PathMapping.bestMatch(for: "/Volumes/MediaX/a.mp4", in: [media, dvr]) == nil)
    }
}

/// A key-value store that suspends inside every read and write, as a file- or `UserDefaults`-backed store may, so
/// unserialized read-modify-write cycles would interleave.
private actor SuspendingKeyValueStore: KeyValueStore {
    private var values: [String: Data] = [:]
    private(set) var writeCount = 0

    func data(forKey key: String) async -> Data? {
        for _ in 0..<5 { await Task.yield() }
        return values[key]
    }

    func setData(_ data: Data?, forKey key: String) async {
        for _ in 0..<5 { await Task.yield() }
        values[key] = data
        writeCount += 1
    }
}
