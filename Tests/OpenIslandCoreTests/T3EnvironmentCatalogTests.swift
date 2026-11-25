import Foundation
import Testing
@testable import OpenIslandCore

struct T3EnvironmentCatalogTests {
    @Test func savedDirectRoutesKeepEnvironmentIdentityAndExcludeDisabledEnvironments() throws {
        let data = Data(#"""
        {"schemaVersion":1,"profiles":[
          {"_tag":"BearerConnectionProfile","connectionId":"one","environmentId":"container","label":"Container","httpBaseUrl":"http://container.orb.local:3773/","wsBaseUrl":"ws://container.orb.local:3773/"},
          {"_tag":"BearerConnectionProfile","connectionId":"two","environmentId":"disabled","label":"Disabled","httpBaseUrl":"https://example.com/","wsBaseUrl":"wss://example.com/"}],
         "credentials":[{"connectionId":"one","credential":{"_tag":"BearerConnectionCredential","token":"fixture"}},
                        {"connectionId":"two","credential":{"_tag":"BearerConnectionCredential","token":"fixture"}}],
         "disabledEnvironmentIds":["disabled"]}
        """#.utf8)
        let environments = try T3EnvironmentCatalog.decode(data)
        #expect(environments.count == 1)
        #expect(environments.first?.environmentID == "container")
        #expect(environments.first?.origin.host == "container.orb.local")
    }

    @Test func decryptsKnownElectronSafeStorageFixtureAndRejectsOtherFormats() throws {
        // Independently generated with OpenSSL AES-128-CBC and PBKDF2-SHA1.
        let fixture = Data(base64Encoded: "djEwFqn+tdzrfhk+szEXB72j6G6ogR1xvJckEjSP5B62KIVFR2Y46pozQSs7M7PkG8MyilL3VHzMA9QXR4cWlkiOYw==")!
        let plaintext = try T3EnvironmentCatalog.decrypt(fixture, password: Data("island-test-key".utf8))
        #expect(try T3EnvironmentCatalog.decode(plaintext).isEmpty)
        #expect(throws: T3EnvironmentCatalog.CatalogError.self) {
            try T3EnvironmentCatalog.decrypt(Data("v20-invalid".utf8), password: Data("island-test-key".utf8))
        }
    }

    @Test func rejectsCredentialURLsAndMismatchedSocketDestinations() {
        for (origin, socket) in [
            ("http://user:secret@localhost:3773", "ws://localhost:3773"),
            ("https://example.com", "ws://example.com"),
            ("https://example.com", "wss://other.example.com"),
            ("file:///tmp/catalog", "ws://localhost")
        ] {
            #expect(throws: T3EnvironmentCatalog.CatalogError.self) {
                try T3EnvironmentCatalog.validate(origin: URL(string: origin)!, webSocketOrigin: URL(string: socket)!)
            }
        }
    }

    @Test func liveSavedEnvironmentSnapshotsAndStreams() async throws {
        guard ProcessInfo.processInfo.environment["OPEN_ISLAND_TEST_T3_CATALOG"] == "1" else { return }
        let environments = try T3EnvironmentCatalog.read()
        for environment in environments {
            let client = T3CodeClient(savedEnvironment: environment)
            let connection = try await client.connect()
            #expect(connection.environmentID == environment.environmentID)
            let snapshot = try await client.snapshot()
            print("Saved T3 environment has \(snapshot.threads.count) thread(s).")
            if let thread = snapshot.threads.first(where: { $0.settledAt == nil && $0.archivedAt == nil }) {
                _ = try await client.threadDetail(threadID: thread.id)
            }
            if let thread = snapshot.threads.first(where: { $0.settledAt == nil && $0.archivedAt == nil }),
               let project = snapshot.projects.first(where: { $0.id == thread.projectId }) {
                _ = try await client.projectFavicon(project)
            }
            let stream = try await client.shellEvents()
            for try await event in stream {
                if case .snapshot = event { break }
            }
            await client.disconnect()
            // Disconnect must not revoke the credential owned by T3 Desktop.
            _ = try await client.connect()
            _ = try await client.snapshot()
            await client.disconnect()
        }
    }

    @Test func liveSavedEnvironmentCatalog() throws {
        guard ProcessInfo.processInfo.environment["OPEN_ISLAND_TEST_T3_CATALOG"] == "1" else { return }
        let environments = try T3EnvironmentCatalog.read()
        #expect(!environments.isEmpty)
        print("Read \(environments.count) saved native T3 environment(s).")
    }
}
