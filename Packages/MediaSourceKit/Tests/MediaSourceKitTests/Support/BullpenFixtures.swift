import Foundation
import MediaSourceKit
import Synchronization

/// Bullpen's shared contract fixtures (copied from its `api/fixtures/`): hosts under `home.example`, placeholder
/// signatures, no tokens or LAN addresses.
enum BullpenFixture {
    static let base = URL(string: "https://bullpen.home.example/")!

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/bullpen")
        else { throw LineupFixture.Missing(name: name) }
        return try Data(contentsOf: url)
    }

    /// The fixture catalog (sign-in required) opened up: no `oidc-issuer`, and the library relation added, as the
    /// owner's open LAN server answers.
    static func openCatalog() throws -> Data {
        let catalog = try data("api-catalog")
        guard var root = try JSONSerialization.jsonObject(with: catalog) as? [String: Any],
              var linkset = root["linkset"] as? [[String: Any]] else { throw LineupFixture.Missing(name: "linkset") }
        linkset[0][BullpenVocabulary.oidcIssuer] = nil
        linkset[0][BullpenVocabulary.library] = [["href": "/opds/root.json", "type": "application/opds+json"]]
        root["linkset"] = linkset
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// An empty last page for the recordings feed's `next` link.
    static let emptyPage = Data(#"{"metadata":{"title":"Recordings"},"links":[],"publications":[]}"#.utf8)

    /// A server answering from the fixtures, by path and query.
    static func server(catalog: Data? = nil) throws -> FixtureFetcher {
        FixtureFetcher(documents: [
            "/.well-known/api-catalog": try catalog ?? openCatalog(),
            "/api/v1/server": try data("server"),
            "/api/v1/channels": try data("channels"),
            "/opds/root.json": try data("opds-root"),
            "/opds/recordings.json": try data("opds-recordings"),
            "/opds/recordings.json?cursor=EXAMPLE-CURSOR": emptyPage
        ])
    }

    static func source(_ fetcher: FixtureFetcher) -> BullpenSource {
        BullpenSource(id: .bullpen(serverID: "bullpen:01a16244-0000-7000-8000-00000000c0de"), name: "Bullpen on den",
                      client: BullpenClient(baseURL: base, fetcher: fetcher))
    }
}

/// Serves documents by path and query, and records what was asked for.
final class FixtureFetcher: RemoteDocumentFetching {
    let documents: [String: Data]
    private let requested = Mutex<[String]>([])

    init(documents: [String: Data]) {
        self.documents = documents
    }

    var requests: [String] { requested.withLock { $0 } }

    func document(at url: URL, accept: String) async throws -> Data {
        let key = url.path(percentEncoded: true) + (url.query(percentEncoded: true).map { "?" + $0 } ?? "")
        requested.withLock { $0.append(key) }
        guard let data = documents[key] else { throw RemoteDocumentError.status(404, nil) }
        return data
    }
}
