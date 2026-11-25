import Foundation
import OpenIslandCore

/// Uses T3's own shell projection and runtime-request API instead of inferring
/// desktop threads from provider processes or installing provider hooks.
@Observable
@MainActor
final class T3CodeCoordinator {
    @ObservationIgnored var onEvent: ((AgentEvent) -> Void)?
    @ObservationIgnored var onStatusMessage: ((String) -> Void)?
    @ObservationIgnored var onAttachmentStatesChanged: (([String: SessionAttachmentState]) -> Void)?
    @ObservationIgnored var isSessionTracked: ((String) -> Bool)?

    private(set) var isLocalConnected = false
    var isConnected: Bool { isLocalConnected || environmentCoordinators.values.contains { $0.isConnected } }
    private(set) var statusMessage = "Not connected to T3 Code."
    private(set) var savedEnvironmentStatusMessage: String?
    private(set) var requiresSavedConnectionAccess = false
    private(set) var requiresForegroundReadAccess = !T3ForegroundThread.hasAccessibilityAccess
    @ObservationIgnored private let discoversSavedEnvironments: Bool
    @ObservationIgnored private var savedEnvironmentTask: Task<Void, Never>?
    @ObservationIgnored private var savedCatalogModificationDate: Date?
    @ObservationIgnored private var savedEnvironments: [String: T3SavedEnvironment] = [:]
    private var environmentCoordinators: [String: T3CodeCoordinator] = [:]
    private(set) var trackedSessionIDs: Set<String> = []

    @ObservationIgnored private let loadDetail: @Sendable (String) async throws -> T3ThreadDetail
    @ObservationIgnored private var detailTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var detailQueue: [String] = []
    private static let maximumDetailRequests = 4

    @ObservationIgnored private let client: T3CodeClient
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?
    @ObservationIgnored private let foregroundThread: () -> T3ForegroundThread?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var environmentID = ""
    @ObservationIgnored private var projects: [T3Project] = []
    @ObservationIgnored private var records: [String: Record] = [:]
    @ObservationIgnored private var projectImages: [String: (project: T3Project, data: Data?)] = [:]
    @ObservationIgnored private var projectImageTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var detailRetryIDs: Set<String> = []
    @ObservationIgnored private var detailRetryTask: Task<Void, Never>?

    private struct Record {
        var thread: T3Thread
        var completionKey: String?
        var permissionID: String?
        var questionID: String?
        var permission: PermissionRequest?
        var question: QuestionPrompt?
        var metadata: T3SessionMetadata?
        var jumpTarget: JumpTarget
    }

    init(client: T3CodeClient = T3CodeClient(), discoversSavedEnvironments: Bool = true,
         foregroundThread: @escaping () -> T3ForegroundThread? = { T3ForegroundThread.current() },
         loadDetail: (@Sendable (String) async throws -> T3ThreadDetail)? = nil) {
        self.client = client
        self.discoversSavedEnvironments = discoversSavedEnvironments
        self.foregroundThread = foregroundThread
        self.loadDetail = loadDetail ?? { try await client.threadDetail(threadID: $0) }
    }

    static func sessionID(environmentID: String, threadID: String) -> String {
        "t3:\(environmentID):\(threadID)"
    }

    func start() {
        guard connectionTask == nil else { return }
        let token = UUID()
        generation = token
        foregroundTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshForegroundReadState()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        if discoversSavedEnvironments {
            savedEnvironmentTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refreshSavedEnvironments()
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
        }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            var retrySeconds = 1
            while !Task.isCancelled && self.generation == token {
                do {
                    let connection = try await self.client.connect()
                    guard !Task.isCancelled, self.generation == token else { break }
                    self.receiveConnection(connection)
                    retrySeconds = 1
                    let events = try await self.client.shellEvents()
                    for try await event in events {
                        guard !Task.isCancelled, self.generation == token else { break }
                        switch event {
                        case let .snapshot(snapshot): await self.receiveSnapshot(snapshot)
                        case let .projectEnrichment(projects, _):
                            for project in projects { self.receiveProject(project) }
                        case let .threadUpdated(thread): await self.receiveThread(thread)
                        case let .threadRemoved(threadID): self.removeThread(threadID)
                        case .snapshotRequired: await self.receiveSnapshot(try await self.client.snapshot())
                        case let .projectUpdated(project):
                            self.receiveProject(project)
                        case let .projectRemoved(projectID): self.projects.removeAll { $0.id == projectID }
                        }
                    }
                    if Task.isCancelled || self.generation != token { break }
                    self.markDisconnected()
                } catch {
                    if Task.isCancelled || self.generation != token { break }
                    self.markDisconnected()
                    self.setStatus("T3 Code unavailable: \(error.localizedDescription)")
                }
                await self.client.disconnect()
                do { try await Task.sleep(for: .seconds(retrySeconds)) }
                catch { break }
                retrySeconds = min(retrySeconds * 2, 15)
            }
            if self.generation == token {
                self.connectionTask = nil
                self.markDisconnected()
            }
        }
    }

    func stop() {
        foregroundTask?.cancel()
        foregroundTask = nil
        savedEnvironmentTask?.cancel()
        savedEnvironmentTask = nil
        for child in environmentCoordinators.values { child.stop() }
        environmentCoordinators.removeAll()
        savedEnvironments.removeAll()
        savedCatalogModificationDate = nil
        generation = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        detailRetryTask?.cancel()
        detailRetryTask = nil
        detailRetryIDs.removeAll()
        markDisconnected()
        statusMessage = "T3 Code connection disabled."
        let client = client
        Task { await client.disconnect() }
    }

    func refreshSavedEnvironments(allowKeychainPrompt: Bool = false) async {
        let token = generation
        do {
            let previousDate = savedCatalogModificationDate
            let (modified, loaded) = try await Task.detached {
                let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata/connection-catalog.json")
                let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
                let modified = attributes?[.modificationDate] as? Date
                if modified == previousDate && !allowKeychainPrompt {
                    return (modified, Optional<[T3SavedEnvironment]>.none)
                }
                return (modified, Optional(try T3EnvironmentCatalog.read(allowKeychainPrompt: allowKeychainPrompt)))
            }.value
            guard !Task.isCancelled, generation == token, let environments = loaded else { return }
            savedCatalogModificationDate = modified
            requiresSavedConnectionAccess = false
            reconcileSavedEnvironments(environments)
            savedEnvironmentStatusMessage = environments.isEmpty ? nil : environmentCoordinators.values
                .map(\.statusMessage).sorted().joined(separator: " ")
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            requiresSavedConnectionAccess = (error as? T3EnvironmentCatalog.CatalogError) == .keychainUnavailable
            savedEnvironmentStatusMessage = error.localizedDescription
        }
    }

    func reconcileSavedEnvironments(_ environments: [T3SavedEnvironment]) {
        let incoming = Set(environments.map(\.environmentID))
        for id in Set(environmentCoordinators.keys).subtracting(incoming) {
            if let child = environmentCoordinators.removeValue(forKey: id) {
                child.stop()
                onAttachmentStatesChanged?(Dictionary(uniqueKeysWithValues: child.trackedSessionIDs.map { ($0, .detached) }))
            }
            savedEnvironments.removeValue(forKey: id)
        }
        for environment in environments where environment.environmentID != environmentID {
            let id = environment.environmentID
            guard savedEnvironments[id] != environment else { continue }
            environmentCoordinators[id]?.stop()
            let child = T3CodeCoordinator(client: T3CodeClient(savedEnvironment: environment), discoversSavedEnvironments: false,
                                          foregroundThread: foregroundThread)
            child.onEvent = { [weak self] in self?.onEvent?($0) }
            child.isSessionTracked = { [weak self] in self?.isSessionTracked?($0) ?? false }
            child.onAttachmentStatesChanged = { [weak self] in self?.onAttachmentStatesChanged?($0) }
            child.onStatusMessage = { [weak self] message in
                self?.savedEnvironmentStatusMessage = "\(environment.label): \(message)"
            }
            savedEnvironments[id] = environment
            environmentCoordinators[id] = child
            child.start()
        }
    }

    private func owningEnvironment(for sessionID: String) -> T3CodeCoordinator? {
        environmentCoordinators.values.first { $0.trackedSessionIDs.contains(sessionID) }
    }

    private func setStatus(_ message: String) {
        statusMessage = message
        onStatusMessage?(message)
    }

    private func markDisconnected() {
        for request in detailTasks.values { request.task.cancel() }
        detailTasks.removeAll()
        detailQueue.removeAll()
        for task in projectImageTasks.values { task.cancel() }
        projectImageTasks.removeAll()
        isLocalConnected = false
        statusMessage = "Disconnected from T3 Code. Reconnecting when available."
        onAttachmentStatesChanged?(Dictionary(uniqueKeysWithValues: trackedSessionIDs.map { ($0, .stale) }))
    }

    func receiveConnection(_ connection: T3ConnectionInfo) {
        if !environmentID.isEmpty && environmentID != connection.environmentID {
            markDisconnected()
            records.removeAll()
            trackedSessionIDs.removeAll()
        }
        environmentID = connection.environmentID
        isLocalConnected = true
        setStatus("Connected to T3 Code.")
    }

    func receiveSnapshot(_ snapshot: T3ShellSnapshot) async {
        let changedProjects = Set(snapshot.projects.filter { project in
            projects.first(where: { $0.id == project.id }) != project
        }.map(\.id))
        projects = snapshot.projects
        for thread in records.values.map(\.thread) where changedProjects.contains(thread.projectId) {
            applyThread(thread, detail: nil, preservingAssistantMessage: true)
        }
        let incoming = Set(snapshot.threads.map(\.id))
        for threadID in Set(records.keys).subtracting(incoming) { removeThread(threadID) }
        // Publish the complete sidebar before any network hydration can suspend us.
        // Queue actionable work first so native controls become ready promptly.
        let threads = snapshot.threads.sorted {
            let left = $0.pendingRuntimeRequest != nil ? 2 : (isRunning($0) ? 1 : 0)
            let right = $1.pendingRuntimeRequest != nil ? 2 : (isRunning($1) ? 1 : 0)
            return left == right ? $0.updatedAt > $1.updatedAt : left > right
        }
        for thread in threads { await receiveThread(thread) }
    }

    func receiveThread(_ thread: T3Thread) async {
        guard isIncluded(thread) else {
            removeThread(thread.id)
            return
        }
        let id = Self.sessionID(environmentID: environmentID, threadID: thread.id)
        let project = projects.first { $0.id == thread.projectId }
        let appearanceIsCurrent = (project == nil || records[thread.id]?.metadata?.projectName == project?.title)
            && records[thread.id]?.metadata?.projectIcon == project?.projectIcon
        if records[thread.id]?.thread == thread, appearanceIsCurrent, !detailRetryIDs.contains(thread.id), isSessionTracked?(id) != false {
            onAttachmentStatesChanged?([id: attachmentState(thread)])
            return
        }
        let previous = records[thread.id]?.thread
        let needsDetail = thread.pendingRuntimeRequest != nil || isRunning(thread)
            || (previous == nil && thread.latestVisibleMessage?.role != "assistant")
            || (previous.map { isRunning($0) } == true && !isRunning(thread))
        // The shell is authoritative for visibility/status and already includes
        // the latest visible message. Never make rendering wait for full history.
        if thread.pendingRuntimeRequest == nil { detailRetryIDs.remove(thread.id) }
        applyThread(thread, detail: nil)
        if needsDetail {
            if !detailQueue.contains(thread.id) { detailQueue.append(thread.id) }
            startQueuedDetails()
        }
    }

    func receiveProject(_ project: T3Project) {
        guard projects.first(where: { $0.id == project.id }) != project else { return }
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        for thread in records.values.map(\.thread) where thread.projectId == project.id {
            applyThread(thread, detail: nil, preservingAssistantMessage: true)
        }
    }

    private func loadProjectImageIfNeeded(_ project: T3Project) {
        guard isLocalConnected, project.projectIcon == nil,
              projectImages[project.id]?.project != project, projectImageTasks[project.id] == nil else { return }
        let token = generation
        let client = client
        projectImageTasks[project.id] = Task { [weak self] in
            let data = try? await client.projectFavicon(project)
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.projectImageTasks.removeValue(forKey: project.id)
            guard self.projects.first(where: { $0.id == project.id }) == project else {
                if let current = self.projects.first(where: { $0.id == project.id }) { self.loadProjectImageIfNeeded(current) }
                return
            }
            self.projectImages[project.id] = (project, data)
            for thread in self.records.values.map(\.thread) where thread.projectId == project.id {
                self.applyThread(thread, detail: nil, preservingAssistantMessage: true)
            }
        }
    }

    private func startQueuedDetails() {
        guard isLocalConnected else { return }
        while detailTasks.count < Self.maximumDetailRequests,
              let index = detailQueue.firstIndex(where: { detailTasks[$0] == nil }) {
            let threadID = detailQueue.remove(at: index)
            guard let thread = records[threadID]?.thread else { continue }
            let requestID = UUID()
            let token = generation
            let loadDetail = loadDetail
            let task = Task { [weak self] in
                let detail = try? await loadDetail(threadID)
                guard let self, !Task.isCancelled, self.generation == token,
                      self.detailTasks[threadID]?.id == requestID else { return }
                self.detailTasks.removeValue(forKey: threadID)
                // A slow response must not resurrect a settled thread or replace
                // a newer streamed status/request with an older projection.
                if self.records[threadID]?.thread == thread {
                    if let detail {
                        self.detailRetryIDs.remove(threadID)
                        self.applyThread(thread, detail: detail)
                    } else if thread.pendingRuntimeRequest != nil {
                        self.detailRetryIDs.insert(threadID)
                        self.scheduleDetailRetry()
                    }
                }
                self.startQueuedDetails()
            }
            detailTasks[threadID] = (requestID, task)
        }
    }

    private func scheduleDetailRetry() {
        guard detailRetryTask == nil else { return }
        detailRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.isLocalConnected else { self?.detailRetryTask = nil; return }
            let pendingThreads = self.detailRetryIDs.compactMap { self.records[$0]?.thread }
            self.detailRetryTask = nil
            for thread in pendingThreads { await self.receiveThread(thread) }
        }
    }

    private func isIncluded(_ thread: T3Thread) -> Bool {
        guard thread.archivedAt == nil, thread.deletedAt == nil,
              thread.settledAt == nil, thread.settledOverride != "settled",
              thread.lineage?.relationshipToParent != "subagent", thread.lineage?.sideChat != true else { return false }
        // Match T3's snoozed placement, including requests that wake a thread.
        if let until = thread.snoozedUntil, timestamp(until) > .now {
            guard let pending = thread.pendingRuntimeRequest else { return false }
            if pending.kind == "user_input", let snoozedAt = thread.snoozedAt,
               timestamp(pending.createdAt) <= timestamp(snoozedAt) { return false }
        }
        return true
    }

    private func parsedTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func timestamp(_ value: String) -> Date { parsedTimestamp(value) ?? .now }

    private func hasUnreadCompletion(_ thread: T3Thread) -> Bool? {
        guard !isRunning(thread), ["completed", "failed", "interrupted", "cancelled", "rolled_back"].contains(thread.status) else { return nil }
        if let foreground = foregroundThread(), foreground.environmentID == environmentID, foreground.threadID == thread.id {
            return false
        }
        if let previous = records[thread.id] {
            // T3 auto-visits the selected chat even in a background window.
            // Observed completions stay unread until that exact chat is frontmost.
            if isRunning(previous.thread) || previous.thread.latestRunId != thread.latestRunId
                || previous.thread.latestRunCompletedAt != thread.latestRunCompletedAt
                || previous.metadata?.hasUnreadCompletion == true { return true }
            // A foreground acknowledgement survives later background updates.
            if previous.metadata?.hasUnreadCompletion == false { return false }
        }
        // A visit before the run ended does not acknowledge its result. Missing
        // or malformed timestamps must not silently clear an unread completion.
        guard let completed = parsedTimestamp(thread.latestRunCompletedAt),
              let visited = parsedTimestamp(thread.lastVisitedAt) else { return true }
        return visited < completed
    }

    func refreshForegroundReadState() {
        requiresForegroundReadAccess = !T3ForegroundThread.hasAccessibilityAccess
        guard records.values.contains(where: { $0.metadata?.hasUnreadCompletion == true }),
              let foreground = foregroundThread(), foreground.environmentID == environmentID,
              let record = records[foreground.threadID], record.metadata?.hasUnreadCompletion == true else { return }
        applyThread(record.thread, detail: nil, preservingAssistantMessage: true)
    }

    private func attachmentState(_ thread: T3Thread) -> SessionAttachmentState {
        .attached // Sidebar placement, not event age, owns native T3 visibility.
    }

    /// Shared by snapshot and stream ingress. A snapshot restores state without
    /// announcing historical completions; only an observed new turn completes.
    func applyThread(_ thread: T3Thread, detail: T3ThreadDetail?, preservingAssistantMessage: Bool = false) {
        guard isIncluded(thread) else {
            removeThread(thread.id)
            return
        }
        let id = Self.sessionID(environmentID: environmentID, threadID: thread.id)
        let previous = records[thread.id]
        let date = timestamp(thread.updatedAt)
        let project = projects.first { $0.id == thread.projectId }
        let cwd = thread.worktreePath ?? project?.workspaceRoot ?? ""
        let jumpTarget = JumpTarget(terminalApp: "T3 Code", workspaceName: project?.title ?? URL(fileURLWithPath: cwd).lastPathComponent,
                                    paneTitle: thread.title, workingDirectory: cwd,
                                    t3ThreadID: thread.id, t3EnvironmentID: environmentID)
        let messages = detail?.messages ?? []
        let shellAssistant = thread.latestVisibleMessage.flatMap { message in
            message.role == "assistant" && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? message.text : nil
        }
        let lastAssistant = (preservingAssistantMessage ? previous?.metadata?.lastAssistantMessage : nil)
            ?? messages.last(where: { $0.role == "assistant" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text
            ?? shellAssistant
        let lastUser = messages.last(where: { $0.role == "user" })?.text
            ?? (thread.latestVisibleMessage?.role == "user" ? thread.latestVisibleMessage?.text : nil)
        let running = isRunning(thread)
        let tool = running ? detail?.turnItems.last(where: { $0.type == "command_execution" })?.input ?? previous?.metadata?.currentTool : nil
        let metadata = T3SessionMetadata(lastAssistantMessage: lastAssistant ?? previous?.metadata?.lastAssistantMessage,
                                        lastUserPrompt: lastUser ?? previous?.metadata?.lastUserPrompt,
                                        initialUserPrompt: previous?.metadata?.initialUserPrompt ?? messages.first(where: { $0.role == "user" })?.text ?? lastUser,
                                        currentTool: tool, model: thread.modelSelection?.model, status: thread.effectiveActivityStatus, hasUnreadCompletion: hasUnreadCompletion(thread),
                                        projectName: project?.title ?? jumpTarget.workspaceName, projectIcon: project?.projectIcon,
                                        projectIconImageData: project.flatMap { projectImages[$0.id]?.project == $0 ? projectImages[$0.id]?.data : nil })
        let summary = running ? (tool ?? "T3 Code is working…") : (lastAssistant ?? "Ready in T3 Code.")
        var record = Record(thread: thread, completionKey: previous?.completionKey,
                            permissionID: previous?.permissionID, questionID: previous?.questionID,
                            permission: previous?.permission, question: previous?.question, metadata: metadata, jumpTarget: jumpTarget)
        if isSessionTracked?(id) == false || (previous == nil && isSessionTracked?(id) != true) {
            record.permissionID = nil
            record.permission = nil
            record.questionID = nil
            record.question = nil
            onEvent?(.sessionStarted(SessionStarted(sessionID: id, title: thread.title, tool: .t3Code, origin: .live,
                                                     initialPhase: running ? .running : .completed,
                                                     summary: summary, timestamp: date, jumpTarget: jumpTarget, t3Metadata: metadata)))
        }
        trackedSessionIDs.insert(id)
        if previous?.metadata != metadata || previous?.thread.title != thread.title || previous?.jumpTarget != jumpTarget || previous == nil {
            onEvent?(.t3SessionMetadataUpdated(T3SessionMetadataUpdated(sessionID: id, t3Metadata: metadata,
                                                                      jumpTarget: jumpTarget, title: thread.title, timestamp: date)))
        }
        if let pending = thread.pendingRuntimeRequest {
            applyPending(pending, detail: detail, sessionID: id, record: &record)
        } else {
            if previous?.permissionID != nil || previous?.questionID != nil {
                onEvent?(.actionableStateResolved(ActionableStateResolved(sessionID: id, summary: summary, timestamp: .now)))
            }
            record.permissionID = nil
            record.permission = nil
            record.questionID = nil
            record.question = nil
            let completionKey = thread.latestRunId ?? thread.updatedAt
            if !running && previous.map({ isRunning($0.thread) }) == true && record.completionKey != completionKey {
                record.completionKey = completionKey
                onEvent?(.sessionCompleted(SessionCompleted(sessionID: id, summary: summary, timestamp: date)))
            } else if previous == nil || previous.map({ isRunning($0.thread) }) != running || previous?.thread.status != thread.status || previous?.thread.activeRunId != thread.activeRunId || previous?.permissionID != nil || previous?.questionID != nil {
                onEvent?(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: summary,
                                                                 phase: running ? .running : .completed, timestamp: date)))
            }
        }
        records[thread.id] = record
        if let project { loadProjectImageIfNeeded(project) }
        onAttachmentStatesChanged?([id: attachmentState(thread)])
    }

    private func isRunning(_ thread: T3Thread) -> Bool {
        thread.isWorking
    }

    private func applyPending(_ pending: T3PendingRequest, detail: T3ThreadDetail?, sessionID: String, record: inout Record) {
        // Shell-only updates must not downgrade already hydrated native controls.
        if detail == nil, record.permissionID == pending.id || record.questionID == pending.id { return }
        let item = detail?.turnItems.last { $0.requestId == pending.id }
        let capability = detail?.runtimeRequests.first { $0.id == pending.id }?.responseCapability.type
        let answerable = ["live", "message"].contains(capability ?? "") && pending.userOnly != true && pending.kind != "auth_refresh"
        if answerable, let questions = item?.questions, !questions.isEmpty, !questions.contains(where: { $0.isSecret == true }) {
            if record.questionID != pending.id {
                let prompt = QuestionPrompt(title: item?.prompt ?? questions.first?.question ?? "T3 Code needs an answer.", questions: questions.map {
                    QuestionPromptItem(question: $0.question, header: $0.header ?? $0.id,
                                       options: ($0.options ?? []).map { QuestionOption(label: $0.label, description: $0.description ?? "") },
                                       multiSelect: $0.multiSelect ?? false)
                })
                record.questionID = pending.id
                record.question = prompt
                record.permissionID = nil
                record.permission = nil
                onEvent?(.questionAsked(QuestionAsked(sessionID: sessionID, prompt: prompt, timestamp: .now)))
            }
        } else {
            let unsupported = !answerable || item?.questions?.contains(where: { $0.isSecret == true }) == true
                || !["command", "file-read", "file-change", "permission", "mcp-elicitation"].contains(pending.kind)
            guard record.permissionID != pending.id || record.permission?.requiresTerminalApproval != unsupported else { return }
            let request = PermissionRequest(title: unsupported ? "Continue in T3 Code" : "T3 Code needs approval",
                                            summary: item?.prompt ?? item?.reason ?? item?.input ?? "Review the pending request in T3 Code.",
                                            affectedPath: "", toolUseID: pending.id, requiresTerminalApproval: unsupported,
                                            nativeOptions: item?.options?.map { NativeApprovalOption(id: $0.decision, label: $0.label, warning: $0.warning) })
            record.permissionID = pending.id
            record.permission = request
            record.questionID = nil
            record.question = nil
            onEvent?(.permissionRequested(PermissionRequested(sessionID: sessionID, request: request, timestamp: .now)))
        }
    }

    func resolvePermission(sessionID: String, resolution: PermissionResolution) async throws {
        try await resolveNativePermission(sessionID: sessionID, decision: resolution.isApproved ? "accept" : "decline")
    }

    func resolveNativePermission(sessionID: String, decision: String) async throws {
        if let owner = owningEnvironment(for: sessionID) {
            return try await owner.resolveNativePermission(sessionID: sessionID, decision: decision)
        }
        let record = try actionableRecord(sessionID)
        guard let requestID = record.permissionID, record.permission?.requiresTerminalApproval != true,
              ["accept", "acceptForSession", "acceptAlways", "decline", "cancel"].contains(decision),
              record.permission?.nativeOptions?.isEmpty != false || record.permission?.nativeOptions?.contains(where: { $0.id == decision }) == true else { throw ActionError.unavailable }
        try await client.respond(threadID: record.thread.id, requestID: requestID, decision: decision)
        await receiveSnapshot(try await client.snapshot())
    }

    func answerQuestion(sessionID: String, response: QuestionPromptResponse) async throws {
        if let owner = owningEnvironment(for: sessionID) {
            return try await owner.answerQuestion(sessionID: sessionID, response: response)
        }
        let record = try actionableRecord(sessionID)
        guard let requestID = record.questionID else { throw ActionError.unavailable }
        let detail = try await client.threadDetail(threadID: record.thread.id)
        guard let questions = detail.turnItems.last(where: { $0.requestId == requestID })?.questions,
              !questions.contains(where: { $0.isSecret == true }) else { throw ActionError.unavailable }
        var answers: [String: CodexHookJSONValue] = [:]
        for question in questions {
            let value = response.answers[question.id] ?? response.answers[question.question]
                ?? response.answers[question.header ?? ""] ?? (questions.count == 1 ? response.rawAnswer : nil)
            guard let value, !value.isEmpty else { throw ActionError.missingAnswer }
            answers[question.id] = .array(Self.answerValues(value, question: question).map(CodexHookJSONValue.string))
        }
        try await client.respond(threadID: record.thread.id, requestID: requestID, answers: answers)
        await receiveSnapshot(try await client.snapshot())
    }

    static func answerValues(_ value: String, question: T3Question) -> [String] {
        guard question.multiSelect == true else { return [value] }
        // The shared UI joins labels in option order. Consume complete labels
        // rather than splitting commas that may be part of a label itself.
        var remainder = value
        var values: [String] = []
        for option in question.options ?? [] {
            if remainder == option.label {
                values.append(option.label)
                remainder = ""
                break
            }
            if remainder.hasPrefix(option.label + ", ") {
                values.append(option.label)
                remainder.removeFirst(option.label.count + 2)
            }
        }
        return remainder.isEmpty ? values : [value]
    }

    func sendReply(sessionID: String, text: String) async throws {
        if let owner = owningEnvironment(for: sessionID) {
            return try await owner.sendReply(sessionID: sessionID, text: text)
        }
        let record = try actionableRecord(sessionID)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isRunning(record.thread), record.thread.pendingRuntimeRequest == nil else { throw ActionError.unavailable }
        try await client.sendMessage(threadID: record.thread.id, text: text)
        await receiveSnapshot(try await client.snapshot())
    }

    private func actionableRecord(_ sessionID: String) throws -> Record {
        guard isLocalConnected, let record = records.values.first(where: {
            Self.sessionID(environmentID: environmentID, threadID: $0.thread.id) == sessionID
        }) else { throw ActionError.unavailable }
        return record
    }

    enum ActionError: LocalizedError {
        case unavailable, missingAnswer
        var errorDescription: String? {
            switch self {
            case .unavailable: "This T3 Code action is no longer available. Open the thread in T3 Code."
            case .missingAnswer: "Answer every question before submitting to T3 Code."
            }
        }
    }

    private func removeThread(_ threadID: String) {
        detailQueue.removeAll { $0 == threadID }
        detailTasks.removeValue(forKey: threadID)?.task.cancel()
        detailRetryIDs.remove(threadID)
        guard records.removeValue(forKey: threadID) != nil else { return }
        let id = Self.sessionID(environmentID: environmentID, threadID: threadID)
        trackedSessionIDs.remove(id)
        onEvent?(.actionableStateResolved(ActionableStateResolved(sessionID: id, summary: "T3 thread closed.", timestamp: .now)))
        onEvent?(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: "T3 thread closed.", phase: .completed, timestamp: .now)))
        onAttachmentStatesChanged?([id: .detached])
        startQueuedDetails()
    }
}
