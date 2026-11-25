import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct T3CodeCoordinatorTests {
    private func coordinator() -> T3CodeCoordinator {
        let coordinator = T3CodeCoordinator()
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://127.0.0.1:3773")!))
        return coordinator
    }

    private func thread(status: String = "completed", run: String? = nil, pending: T3PendingRequest? = nil) -> T3Thread {
        T3Thread(id: "thread", title: "Fix the app", projectId: "project", status: status,
                 activeRunId: run, latestRunId: "run-1", updatedAt: "2026-11-24T18:00:00Z", pendingRuntimeRequest: pending,
                 latestVisibleMessage: T3Message(role: "assistant", text: "Finished the change."))
    }

    private func detail(questions: [T3Question]? = nil, capability: String = "live") -> T3ThreadDetail {
        T3ThreadDetail(messages: [T3Message(role: "user", text: "Fix the app")],
                       runtimeRequests: [T3RuntimeRequest(id: "request", kind: questions == nil ? "command" : "user_input", status: "pending", responseCapability: T3ResponseCapability(type: capability))],
                       turnItems: [T3TurnItem(type: questions == nil ? "approval" : "user_input", requestId: "request", prompt: "Review this request", questions: questions)])
    }

    @Test func initialCompletedSnapshotDoesNotAnnounceHistoricalCompletion() {
        let coordinator = coordinator()
        var events: [AgentEvent] = []
        coordinator.onEvent = { events.append($0) }
        coordinator.applyThread(thread(), detail: nil)
        #expect(events.contains { if case .sessionStarted = $0 { return true }; return false })
        #expect(!events.contains { if case .sessionCompleted = $0 { return true }; return false })
        guard case let .sessionStarted(start) = events.first else { Issue.record("Missing session"); return }
        #expect(start.sessionID == "t3:local:thread")
        #expect(start.tool == .t3Code)
        #expect(start.jumpTarget?.t3ThreadID == "thread")
        #expect(start.jumpTarget?.t3EnvironmentID == "local")
        #expect(start.t3Metadata?.lastAssistantMessage == "Finished the change.")
    }

    @Test func runningPreviewKeepsLatestNonemptyAssistantMessageInsteadOfToolActivity() {
        let coordinator = coordinator()
        var state = SessionState()
        coordinator.onEvent = { state.apply($0) }
        var input = thread(status: "running", run: "run-1")
        let detail = T3ThreadDetail(messages: [
            T3Message(role: "assistant", text: "I’m checking the database connection."),
            T3Message(role: "assistant", text: "  ")
        ], turnItems: [T3TurnItem(type: "command_execution", input: "psql --version")])
        coordinator.applyThread(input, detail: detail)
        coordinator.receiveProject(T3Project(id: "project", title: "Project", workspaceRoot: "/tmp",
                                            projectIcon: T3ProjectIcon(kind: "lucide", name: "rocket", color: "violet")))
        #expect(state.session(id: "t3:local:thread")?.islandAssistantPreviewText == "I’m checking the database connection.")
        input.latestVisibleMessage = T3Message(role: "assistant", text: "  ")
        coordinator.applyThread(input, detail: nil)
        #expect(state.session(id: "t3:local:thread")?.islandAssistantPreviewText == "I’m checking the database connection.")
    }

    @Test func projectIconChangesUpdateRowsWithoutResettingNativeQuestionControls() {
        let coordinator = coordinator()
        var state = SessionState()
        coordinator.onEvent = { state.apply($0) }
        var project = T3Project(id: "project", title: "Project", workspaceRoot: "/tmp",
                                projectIcon: T3ProjectIcon(kind: "lucide", name: "rocket", color: "violet"))
        coordinator.receiveProject(project)
        let pending = T3PendingRequest(id: "request", kind: "user_input", createdAt: "now")
        coordinator.applyThread(thread(status: "waiting", run: "run-1", pending: pending),
                                detail: detail(questions: [T3Question(id: "choice", question: "Which?")]))
        let questionID = state.session(id: "t3:local:thread")?.questionPrompt?.id
        #expect(state.session(id: "t3:local:thread")?.t3Metadata?.projectIcon == project.projectIcon)
        project.projectIcon = T3ProjectIcon(kind: "monogram", color: "red", text: "OI")
        coordinator.receiveProject(project)
        #expect(state.session(id: "t3:local:thread")?.t3Metadata?.projectIcon == project.projectIcon)
        #expect(state.session(id: "t3:local:thread")?.questionPrompt?.id == questionID)
        #expect(state.session(id: "t3:local:thread")?.phase == .waitingForAnswer)
    }

    @Test func unchangedThreadStillReceivesProjectAppearanceFromANewerSnapshot() async {
        let coordinator = coordinator()
        var state = SessionState()
        coordinator.onEvent = { state.apply($0) }
        var project = T3Project(id: "project", title: "Project", workspaceRoot: "/tmp",
                                projectIcon: T3ProjectIcon(kind: "emoji", emoji: "🚀"))
        await coordinator.receiveSnapshot(T3ShellSnapshot(threads: [thread()], projects: [project], snapshotSequence: 1))
        project.projectIcon = T3ProjectIcon(kind: "lucide", name: "database", color: "green")
        await coordinator.receiveSnapshot(T3ShellSnapshot(threads: [thread()], projects: [project], snapshotSequence: 2))
        #expect(state.session(id: "t3:local:thread")?.t3Metadata?.projectIcon == project.projectIcon)
    }

    @Test func waitingForChildrenAndCommandsStaysRunningUntilAllWorkFinishes() {
        let coordinator = coordinator()
        var state = SessionState()
        var completions = 0
        coordinator.onEvent = {
            state.apply($0)
            if case .sessionCompleted = $0 { completions += 1 }
        }
        coordinator.applyThread(thread(status: "running", run: "run-1"), detail: nil)
        var waiting = thread()
        waiting.pendingBackgroundTasks = [T3BackgroundTask(taskId: "child", kind: "subagent")]
        coordinator.applyThread(waiting, detail: nil)
        let sessionID = "t3:local:thread"
        #expect(state.session(id: sessionID)?.phase == .running)
        #expect(state.session(id: sessionID)?.t3Metadata?.status == "waiting")
        #expect(state.session(id: sessionID)?.t3Metadata?.hasUnreadCompletion == nil)
        #expect(state.session(id: sessionID)?.islandStatus(at: .now, completedStaleThreshold: 300) == .running)
        #expect(completions == 0)
        waiting.pendingBackgroundTasks = [T3BackgroundTask(taskId: "command", kind: "command", awaited: true)]
        coordinator.applyThread(waiting, detail: nil)
        #expect(state.session(id: sessionID)?.phase == .running)
        #expect(completions == 0)
        waiting.pendingBackgroundTasks = []
        coordinator.applyThread(waiting, detail: nil)
        coordinator.applyThread(waiting, detail: nil)
        #expect(state.session(id: sessionID)?.phase == .completed)
        #expect(completions == 1)
    }

    @Test func completedThreadReturnsToRunningWhenOnlyBackgroundWaitChanges() {
        let coordinator = coordinator()
        var state = SessionState()
        coordinator.onEvent = { state.apply($0) }
        var input = thread()
        coordinator.applyThread(input, detail: nil)
        input.activityRunStatus = "waiting"
        coordinator.applyThread(input, detail: nil)
        #expect(state.session(id: "t3:local:thread")?.phase == .running)
        #expect(state.session(id: "t3:local:thread")?.spotlightStatusLabel != "Completed")
        input.activityRunStatus = nil
        input.blockedOnThreadWait = true
        coordinator.applyThread(input, detail: nil)
        #expect(state.session(id: "t3:local:thread")?.phase == .running)
    }

    @Test func observedCompletionIsAnnouncedOnce() {
        let coordinator = coordinator()
        var events: [AgentEvent] = []
        coordinator.onEvent = { events.append($0) }
        coordinator.applyThread(thread(status: "running", run: "run-1"), detail: nil)
        coordinator.applyThread(thread(), detail: nil)
        coordinator.applyThread(thread(), detail: nil)
        #expect(events.filter { if case .sessionCompleted = $0 { return true }; return false }.count == 1)
    }

    @Test func pendingInteractionKeepsIdentityAndAuthoritativeResolutionClearsIt() {
        let coordinator = coordinator()
        var state = SessionState()
        var events: [AgentEvent] = []
        coordinator.onEvent = { state.apply($0); events.append($0) }
        let pending = T3PendingRequest(id: "request", kind: "command", createdAt: "now")
        coordinator.applyThread(thread(status: "running", run: "run-1", pending: pending), detail: detail())
        let permissionID = state.session(id: "t3:local:thread")?.permissionRequest?.id
        coordinator.applyThread(thread(status: "running", run: "run-1", pending: pending), detail: detail())
        #expect(state.session(id: "t3:local:thread")?.permissionRequest?.id == permissionID)
        #expect(events.filter { if case .permissionRequested = $0 { return true }; return false }.count == 1)
        coordinator.applyThread(thread(status: "running", run: "run-1"), detail: nil)
        #expect(state.session(id: "t3:local:thread")?.permissionRequest == nil)
        #expect(state.session(id: "t3:local:thread")?.phase == .running)
    }

    @Test func structuredQuestionsAndUnsupportedSecretRequestsAreDistinct() {
        let coordinator = coordinator()
        var state = SessionState()
        coordinator.onEvent = { state.apply($0) }
        let pending = T3PendingRequest(id: "request", kind: "user_input", createdAt: "now")
        coordinator.applyThread(thread(status: "waiting", run: "run-1", pending: pending), detail: detail(questions: [T3Question(id: "choice", question: "Which option?", options: [T3QuestionOption(label: "One")])]))
        #expect(state.session(id: "t3:local:thread")?.questionPrompt?.questions.first?.options.first?.label == "One")
        coordinator.applyThread(thread(status: "waiting", run: "run-1", pending: pending), detail: detail(questions: [T3Question(id: "password", question: "Enter secret", isSecret: true)]))
        #expect(state.session(id: "t3:local:thread")?.questionPrompt == nil)
        #expect(state.session(id: "t3:local:thread")?.permissionRequest?.requiresTerminalApproval == true)
    }

    @Test func disconnectStalesWithoutInventingCompletionAndReconnectPreservesPending() {
        let coordinator = coordinator()
        var events: [AgentEvent] = []
        var attachments: [String: SessionAttachmentState] = [:]
        coordinator.onEvent = { events.append($0) }
        coordinator.onAttachmentStatesChanged = { attachments.merge($0) { _, new in new } }
        coordinator.applyThread(thread(status: "running", run: "run-1"), detail: nil)
        coordinator.stop()
        #expect(attachments["t3:local:thread"] == .stale)
        #expect(!coordinator.isConnected)
        #expect(!events.contains { if case .sessionCompleted = $0 { return true }; return false })
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://localhost:3773")!))
        coordinator.applyThread(thread(status: "running", run: "run-1"), detail: nil)
        #expect(attachments["t3:local:thread"] == .attached)
        #expect(events.filter { if case .sessionStarted = $0 { return true }; return false }.count == 1)
    }

    @Test func archiveRemovesControlsWithoutCompletionNotification() {
        let coordinator = coordinator()
        var events: [AgentEvent] = []
        var attachments: [String: SessionAttachmentState] = [:]
        coordinator.onEvent = { events.append($0) }
        coordinator.onAttachmentStatesChanged = { attachments.merge($0) { _, new in new } }
        coordinator.applyThread(thread(status: "running", run: "run-1"), detail: nil)
        var archived = thread()
        archived.archivedAt = "2026-11-24T18:01:00Z"
        coordinator.applyThread(archived, detail: nil)
        #expect(coordinator.trackedSessionIDs.isEmpty)
        #expect(attachments["t3:local:thread"] == .detached)
        #expect(!events.contains { if case .sessionCompleted = $0 { return true }; return false })
    }

    @Test func actionsRequireConnectedAuthoritativeRequest() async {
        let coordinator = T3CodeCoordinator()
        await #expect(throws: T3CodeCoordinator.ActionError.self) {
            try await coordinator.resolvePermission(sessionID: "t3:local:thread", resolution: .allowOnce())
        }
        await #expect(throws: T3CodeCoordinator.ActionError.self) {
            try await coordinator.sendReply(sessionID: "t3:local:thread", text: "Continue")
        }
    }

    @Test func settledThreadsAreExcludedEvenWhenRunningOrAwaitingApproval() {
        let coordinator = coordinator()
        var events: [AgentEvent] = []
        coordinator.onEvent = { events.append($0) }
        var settled = thread()
        settled.settledAt = "now"
        coordinator.applyThread(settled, detail: nil)
        #expect(events.isEmpty)
        settled.pendingRuntimeRequest = T3PendingRequest(id: "request", kind: "command", createdAt: "now")
        coordinator.applyThread(settled, detail: detail())
        settled.status = "running"
        settled.activeRunId = "run-1"
        coordinator.applyThread(settled, detail: detail())
        #expect(events.isEmpty)
        settled.settledAt = nil
        settled.settledOverride = "settled"
        coordinator.applyThread(settled, detail: detail())
        #expect(events.isEmpty)
    }

    @Test func deletedLocalRowIsRecreatedWithoutLosingPendingControls() {
        let coordinator = coordinator()
        var state = SessionState()
        coordinator.isSessionTracked = { state.session(id: $0) != nil }
        coordinator.onEvent = { state.apply($0) }
        let pending = T3PendingRequest(id: "request", kind: "command", createdAt: "now")
        let input = thread(status: "running", run: "run-1", pending: pending)
        coordinator.applyThread(input, detail: detail())
        state = SessionState()
        coordinator.applyThread(input, detail: detail())
        #expect(state.session(id: "t3:local:thread")?.permissionRequest != nil)
    }

    @Test func multiselectPreservesLabelsContainingCommas() {
        let question = T3Question(id: "choice", question: "Choose", options: [T3QuestionOption(label: "A, B"), T3QuestionOption(label: "C"), T3QuestionOption(label: "D")], multiSelect: true)
        #expect(T3CodeCoordinator.answerValues("A, B, D", question: question) == ["A, B", "D"])
        #expect(T3CodeCoordinator.answerValues("custom, free text", question: question) == ["custom, free text"])
    }

    @Test func pendingDetailRecoveryEnablesNativeApprovalChoices() {
        let coordinator = coordinator()
        var state = SessionState()
        coordinator.onEvent = { state.apply($0) }
        let pending = T3PendingRequest(id: "request", kind: "command", createdAt: "now")
        let input = thread(status: "running", run: "run-1", pending: pending)
        coordinator.applyThread(input, detail: nil)
        #expect(state.session(id: "t3:local:thread")?.permissionRequest?.requiresTerminalApproval == true)
        var recovered = detail()
        recovered.turnItems[0].options = [T3ApprovalOption(decision: "acceptAlways", label: "Always allow", warning: "Persists permission")]
        coordinator.applyThread(input, detail: recovered)
        let request = state.session(id: "t3:local:thread")?.permissionRequest
        #expect(request?.requiresTerminalApproval == false)
        #expect(request?.nativeOptions?.first?.id == "acceptAlways")
        #expect(request?.nativeOptions?.first?.warning == "Persists permission")
    }
    @Test func shellUpdatesPreserveHydratedQuestionControls() {
        let coordinator = coordinator()
        var state = SessionState()
        coordinator.onEvent = { state.apply($0) }
        let pending = T3PendingRequest(id: "request", kind: "user_input", createdAt: "now")
        let input = thread(status: "waiting", run: "run-1", pending: pending)
        coordinator.applyThread(input, detail: detail(questions: [T3Question(id: "choice", question: "Which?")]))
        let questionID = state.session(id: "t3:local:thread")?.questionPrompt?.id
        coordinator.applyThread(input, detail: nil)
        #expect(state.session(id: "t3:local:thread")?.questionPrompt?.id == questionID)
        #expect(state.session(id: "t3:local:thread")?.phase == .waitingForAnswer)
    }

    @Test(.timeLimit(.minutes(1))) func entireSnapshotAppearsWhileDetailRequestsAreBlocked() async {
        let gate = DetailGate()
        let coordinator = T3CodeCoordinator(loadDetail: { await gate.load($0) })
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://localhost:3773")!))
        var state = SessionState()
        coordinator.onEvent = { state.apply($0) }
        let threads = (0..<12).map { index in
            T3Thread(id: "thread-\(index)", title: "Agent \(index)", projectId: "project", status: "running",
                     activeRunId: "run", updatedAt: "2026-11-24T18:00:00Z")
        }
        await coordinator.receiveSnapshot(T3ShellSnapshot(threads: threads, projects: [], snapshotSequence: 1))
        // All rows exist even though no detail response has been allowed through.
        #expect(state.sessions.count == 12)
        await gate.waitForRequests(4)
        #expect(await gate.requestedIDs.count == 4)
        #expect(state.sessions.allSatisfy { $0.phase == .running })
        coordinator.stop()
        await gate.releaseAll()
    }

    @Test(.timeLimit(.minutes(1))) func slowDetailsCannotUndoNewerStatusOrSettlement() async {
        let gate = DetailGate()
        let coordinator = T3CodeCoordinator(loadDetail: { await gate.load($0) })
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://localhost:3773")!))
        var state = SessionState()
        coordinator.onEvent = { state.apply($0) }
        let threads = (0..<8).map { index in
            T3Thread(id: "thread-\(index)", title: "Agent \(index)", projectId: "project", status: "running",
                     activeRunId: "run", updatedAt: "2026-11-24T18:00:00Z")
        }
        await coordinator.receiveSnapshot(T3ShellSnapshot(threads: threads, projects: [], snapshotSequence: 1))
        await gate.waitForRequests(4)
        let requested = await gate.requestedIDs
        var completed = threads.first { $0.id == requested[0] }!
        completed.status = "completed"
        completed.activeRunId = nil
        completed.updatedAt = "2026-11-24T18:01:00Z"
        await coordinator.receiveThread(completed)
        await gate.release(requested[0])
        // Starting the next queued request proves the old response was handled.
        await gate.waitForRequests(5)
        #expect(state.session(id: "t3:local:\(completed.id)")?.phase == .completed)
        #expect(state.session(id: "t3:local:\(completed.id)")?.t3Metadata?.currentTool == nil)
        var settled = threads.first { $0.id == requested[1] }!
        settled.settledAt = "2026-11-24T18:01:00Z"
        await coordinator.receiveThread(settled)
        await gate.release(settled.id)
        await gate.waitForRequests(6)
        #expect(!coordinator.trackedSessionIDs.contains("t3:local:\(settled.id)"))
        coordinator.stop()
        await gate.releaseAll()
    }

    @Test(.timeLimit(.minutes(1))) func historyWithoutMessagePreviewHydratesAfterAppearing() async {
        let gate = DetailGate()
        let coordinator = T3CodeCoordinator(loadDetail: { await gate.load($0) })
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://localhost:3773")!))
        var input = thread()
        input.latestVisibleMessage = nil
        await coordinator.receiveSnapshot(T3ShellSnapshot(threads: [input], projects: [], snapshotSequence: 1))
        #expect(coordinator.trackedSessionIDs.count == 1)
        await gate.waitForRequests(1)
        #expect(await gate.requestedIDs == [input.id])
        coordinator.stop()
        await gate.releaseAll()
    }

    @Test func completedHistoryDoesNotRequestFullTranscripts() async {
        let gate = DetailGate()
        let coordinator = T3CodeCoordinator(loadDetail: { await gate.load($0) })
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://localhost:3773")!))
        await coordinator.receiveSnapshot(T3ShellSnapshot(threads: [thread()], projects: [], snapshotSequence: 1))
        await Task.yield()
        #expect(coordinator.trackedSessionIDs.count == 1)
        #expect(await gate.requestedIDs.isEmpty)
        coordinator.stop()
        await gate.releaseAll()
    }

}


private actor DetailGate {
    private(set) var requestedIDs: [String] = []
    private var pending: [String: CheckedContinuation<T3ThreadDetail, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func load(_ id: String) async -> T3ThreadDetail {
        await withCheckedContinuation { continuation in
            pending[id] = continuation
            requestedIDs.append(id)
            let ready = waiters.filter { requestedIDs.count >= $0.0 }
            waiters.removeAll { requestedIDs.count >= $0.0 }
            for waiter in ready { waiter.1.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requestedIDs.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func release(_ id: String) {
        pending.removeValue(forKey: id)?.resume(returning: T3ThreadDetail(
            turnItems: [T3TurnItem(type: "command_execution", input: "old command")]))
    }

    func releaseAll() {
        for id in Array(pending.keys) { release(id) }
    }
}
