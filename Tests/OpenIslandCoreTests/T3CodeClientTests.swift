import Foundation
import Testing
@testable import OpenIslandCore

struct T3CodeClientTests {
    @Test func threadIdentifiersRemainOneEncodedRouteSegment() throws {
        let base = URL(string: "http://localhost:3773/api/orchestration/threads")!
        let url = try T3CodeClient.threadDetailURL(base: base, threadID: "thread:/root/test%3Aitem?#")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/api/orchestration/threads/thread%3A%2Froot%2Ftest%253Aitem%3F%23")
        #expect(url.query == nil)
        #expect(url.fragment == nil)
        #expect(throws: T3CodeError.self) { try T3CodeClient.threadDetailURL(base: base, threadID: "..") }
    }

    @Test func rejectsNonlocalOriginsAndCredentialURLs() throws {
        for value in ["https://example.com", "http://192.168.1.1:3773", "http://user:pass@localhost:3773", "http://localhost:3773?token=secret", "http://localhost:3773/api"] {
            #expect(throws: T3CodeError.self) { try T3CodeClient.validateLocalOrigin(URL(string: value)!) }
        }
        try T3CodeClient.validateLocalOrigin(URL(string: "http://127.0.0.1:3773")!)
        try T3CodeClient.validateLocalOrigin(URL(string: "http://[::1]:3773")!)
    }

    @Test func decodesShellEventsAndIgnoresUnknownEventKinds() throws {
        let json = """
        {"kind":"thread.updated","sequence":3,"thread":{"id":"thread-1","title":"Fix build","projectId":"project-1","status":"waiting","activeRunId":"run-1","updatedAt":"2026-11-24T12:00:00Z","pendingRuntimeRequest":{"id":"request-1","kind":"command","createdAt":"2026-11-24T12:00:00Z"},"futureField":true}}
        """
        let value = try JSONDecoder().decode(CodexHookJSONValue.self, from: Data(json.utf8))
        guard case let .threadUpdated(thread) = try T3CodeClient.shellEvent(value) else { Issue.record("Expected thread update"); return }
        #expect(thread.pendingRuntimeRequest?.id == "request-1")
        #expect(thread.status == "waiting")
        #expect(try T3CodeClient.shellEvent(.object(["kind": .string("synchronized")])) == nil)
        #expect(try T3CodeClient.shellEvent(.object(["kind": .string("snapshot-required")])) == .snapshotRequired)
    }

    @Test func projectIdentityEnrichmentDoesNotBecomeAnEmptyAuthoritativeSnapshot() throws {
        let json = """
        {"kind":"snapshot","snapshot":{"snapshotSequence":42,"threads":[],"archivedThreads":[],"projects":[{"id":"p","title":"Project","workspaceRoot":"/tmp/project"}]},"resolvedRepositoryIdentityRoots":["/tmp/project"]}
        """
        let value = try JSONDecoder().decode(CodexHookJSONValue.self, from: Data(json.utf8))
        guard case let .projectEnrichment(projects, roots) = try T3CodeClient.shellEvent(value) else {
            Issue.record("Marked project enrichment must preserve existing threads"); return
        }
        #expect(projects.map(\.id) == ["p"])
        #expect(roots == ["/tmp/project"])
        var authoritative = value.t3Object
        authoritative.removeValue(forKey: "resolvedRepositoryIdentityRoots")
        guard case let .snapshot(snapshot) = try T3CodeClient.shellEvent(.object(authoritative)) else {
            Issue.record("Unmarked empty snapshot must remain authoritative"); return
        }
        #expect(snapshot.threads.isEmpty)
        #expect(snapshot.snapshotSequence == 42)
    }

    @Test func decodesNativeVisitAndCompletionTimes() throws {
        let json = """
        {"id":"thread","title":"Read state","projectId":"project","status":"completed","updatedAt":"2026-11-24T18:01:00Z","latestRunCompletedAt":"2026-11-24T18:00:00Z","lastVisitedAt":"2026-11-24T18:01:00Z"}
        """
        let thread = try JSONDecoder().decode(T3Thread.self, from: Data(json.utf8))
        #expect(thread.latestRunCompletedAt == "2026-11-24T18:00:00Z")
        #expect(thread.lastVisitedAt == "2026-11-24T18:01:00Z")
    }

    @Test func decodesNativeInteractionDetail() throws {
        let json = """
        {"projection":{"messages":[{"role":"assistant","text":"Please choose"}],"runtimeRequests":[{"id":"r","kind":"user_input","status":"pending","responseCapability":{"type":"live","providerSessionId":"p"}}],"turnItems":[{"id":"i","type":"user_input_request","requestId":"r","questions":[{"id":"q","header":"Choice","question":"Which one?","options":[{"label":"One","description":"First"}],"multiSelect":true}]}]}}
        """
        let detail = try JSONDecoder().decode(T3ThreadDetail.self, from: Data(json.utf8))
        #expect(detail.runtimeRequests.first?.responseCapability.type == "live")
        #expect(detail.turnItems.first?.questions?.first?.multiSelect == true)
        #expect(detail.messages.first?.text == "Please choose")
    }

    /// Explicit opt-in: creates and revokes a short-lived scoped session on the
    /// installed local T3 server; never mutates a thread or starts a model run.
    @Test func liveNativeSnapshotAndStream() async throws {
        guard ProcessInfo.processInfo.environment["OPEN_ISLAND_TEST_T3_LIVE"] == "1" else { return }
        let client = T3CodeClient()
        let info = try await client.connect()
        #expect(!info.environmentID.isEmpty)
        let snapshot = try await client.snapshot()
        #expect(!snapshot.projects.isEmpty)
        if let threadID = ProcessInfo.processInfo.environment["OPEN_ISLAND_TEST_T3_THREAD"] {
            _ = try await client.threadDetail(threadID: threadID)
        } else if let thread = snapshot.threads.last {
            _ = try await client.threadDetail(threadID: thread.id)
        }
        if let thread = snapshot.threads.first(where: { $0.settledAt == nil && $0.archivedAt == nil }),
           let project = snapshot.projects.first(where: { $0.id == thread.projectId }) {
            _ = try await client.projectFavicon(project)
        }
        let stream = try await client.shellEvents()
        for try await event in stream {
            guard case let .snapshot(initial) = event else { continue }
            #expect(initial.snapshotSequence >= snapshot.snapshotSequence)
            break
        }
        await client.disconnect()
    }
}
