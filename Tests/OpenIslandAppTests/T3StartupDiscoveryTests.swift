import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct T3StartupDiscoveryTests {
    @Test func restoringCodexCachePreservesAlreadyConnectedNativeThreads() {
        let native = AgentSession(id: "t3:local:test", title: "Native test", tool: .t3Code,
                                  origin: .live, attachmentState: .attached, phase: .waitingForAnswer,
                                  summary: "Choose", updatedAt: .now,
                                  questionPrompt: QuestionPrompt(title: "Choose", options: ["One", "Two"]))
        let cached = AgentSession(id: "cached", title: "Cached Codex", tool: .codex,
                                  phase: .completed, summary: "Done", updatedAt: .now)
        var state = SessionState(sessions: [native])
        let discovery = SessionDiscoveryCoordinator()
        discovery.stateAccessor = { state }
        discovery.stateUpdater = { state = $0 }
        discovery.applyStartupDiscoveryPayload(.init(
            codexRecords: [CodexTrackedSessionRecord(session: cached)], codexRecordsNeedPrune: false,
            claudeRecords: [], claudeRecordsNeedPrune: false, openCodeRecords: [], openCodeRecordsNeedPrune: false,
            cursorRecords: [], cursorRecordsNeedPrune: false, piRecords: [], piRecordsNeedPrune: false,
            discoveredCodexRecords: [], discoveredClaudeSessions: [], hooksBinaryURL: nil))
        #expect(state.session(id: native.id)?.questionPrompt == native.questionPrompt)
        #expect(state.session(id: native.id)?.phase == .waitingForAnswer)
        #expect(state.session(id: cached.id) != nil)
    }
    @Test func nativeThreadsWithTheSameTitleRemainDistinct() {
        let model = AppModel()
        model.state = SessionState(sessions: ["one", "two"].map { id in
            AgentSession(id: "t3:local:\(id)", title: "Same title", tool: .t3Code,
                         origin: .live, attachmentState: .attached, phase: .running,
                         summary: "Working", updatedAt: .now,
                         jumpTarget: JumpTarget(terminalApp: "T3 Code", workspaceName: "Project", paneTitle: "Same title", workingDirectory: "/tmp/project"))
        })
        #expect(model.surfacedSessions.count == 2)
    }

    @Test func nativeSnapshotKeepsOldUnsettledSidebarThreads() async {
        let coordinator = T3CodeCoordinator()
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://127.0.0.1:3773")!))
        var started: [String] = []
        coordinator.onEvent = { if case let .sessionStarted(event) = $0 { started.append(event.sessionID) } }
        let old = T3Thread(id: "old", title: "History", projectId: "project", status: "completed", updatedAt: "2020-01-01T00:00:00Z")
        let active = T3Thread(id: "active", title: "Work", projectId: "project", status: "running", activeRunId: "run", updatedAt: "2026-11-24T00:00:00Z")
        await coordinator.receiveSnapshot(T3ShellSnapshot(threads: [old, active], projects: [], snapshotSequence: 1))
        #expect(started == ["t3:local:active", "t3:local:old"])
    }

    @Test func settlementRemovesTheThreadFromEveryIslandListAndUnsettlingRestoresIt() {
        let model = AppModel()
        let coordinator = model.t3Code
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://localhost:3773")!))
        var thread = T3Thread(id: "visible", title: "Sidebar thread", projectId: "project", status: "running", activeRunId: "run", updatedAt: "2020-01-01T00:00:00Z")
        coordinator.applyThread(thread, detail: nil)
        #expect(model.islandListSessions.count == 1)
        thread.settledAt = "2026-11-24T00:00:00Z"
        coordinator.applyThread(thread, detail: nil)
        #expect(model.allSessions.isEmpty)
        #expect(model.recentSessions.isEmpty)
        thread.settledAt = nil
        thread.status = "completed"
        thread.activeRunId = nil
        coordinator.applyThread(thread, detail: nil)
        #expect(model.islandListSessions.count == 1)
        let restored = model.islandListSessions[0]
        #expect(restored.phase == .completed)
        #expect(restored.spotlightStatusLabel == "Completed")
        #expect(restored.islandPresence(at: .now) == .active)
        #expect(!restored.isStaleCompletedForIsland(at: .now))
    }

    @Test func hiddenChildrenAndSnoozedThreadsDoNotAppearAsSidebarAgents() {
        let model = AppModel()
        let coordinator = model.t3Code
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://localhost:3773")!))
        var thread = T3Thread(id: "hidden", title: "Hidden", projectId: "project", status: "running", updatedAt: "2020-01-01T00:00:00Z")
        thread.lineage = T3ThreadLineage(relationshipToParent: "subagent")
        coordinator.applyThread(thread, detail: nil)
        thread.lineage = T3ThreadLineage(sideChat: true)
        coordinator.applyThread(thread, detail: nil)
        thread.lineage = nil
        thread.snoozedUntil = "2099-01-01T00:00:00Z"
        coordinator.applyThread(thread, detail: nil)
        #expect(model.allSessions.isEmpty)
        thread.snoozedUntil = nil
        thread.status = "idle"
        coordinator.applyThread(thread, detail: nil)
        #expect(model.islandListSessions.count == 1)
        #expect(model.islandListSessions[0].spotlightStatusLabel == "Idle")
        #expect(model.islandListSessions[0].islandPresence(at: .now) == .inactive)
    }

    @Test(.timeLimit(.minutes(1))) func liveSavedEnvironmentRowsKeepNativeIdentityAndDetachIndependently() async throws {
        guard ProcessInfo.processInfo.environment["OPEN_ISLAND_TEST_T3_CATALOG"] == "1" else { return }
        let environments = try T3EnvironmentCatalog.read()
        guard let remote = environments.first else { Issue.record("Missing saved environment"); return }
        let coordinator = T3CodeCoordinator()
        var state = SessionState()
        var attachments: [String: SessionAttachmentState] = [:]
        let (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        coordinator.isSessionTracked = { state.session(id: $0) != nil }
        coordinator.onEvent = { state.apply($0); continuation.yield($0) }
        coordinator.onAttachmentStatesChanged = { attachments.merge($0) { _, new in new } }
        coordinator.start()
        defer { coordinator.stop(); continuation.finish() }
        for await event in events {
            guard case let .sessionStarted(start) = event,
                  start.jumpTarget?.t3EnvironmentID == remote.environmentID else { continue }
            #expect(start.sessionID == T3CodeCoordinator.sessionID(environmentID: remote.environmentID,
                                                                  threadID: start.jumpTarget!.t3ThreadID!))
            #expect(state.session(id: start.sessionID)?.tool == .t3Code)
            coordinator.reconcileSavedEnvironments([])
            #expect(attachments[start.sessionID] == .detached)
            break
        }
    }

}
