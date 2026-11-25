import Foundation

// Native T3 orchestration protocol 2 wire models. Unknown fields remain forward compatible.
public struct T3ConnectionInfo: Codable, Equatable, Sendable {
    public var environmentID: String
    public var origin: URL

    public init(environmentID: String, origin: URL) {
        self.environmentID = environmentID
        self.origin = origin
    }
}

/// T3's native project appearance union. Unknown kinds safely use a monogram.
public struct T3ProjectIcon: Codable, Equatable, Sendable {
    public var kind: String
    public var name: String?
    public var color: String?
    public var text: String?
    public var emoji: String?

    public init(kind: String, name: String? = nil, color: String? = nil, text: String? = nil, emoji: String? = nil) {
        self.kind = kind
        self.name = name
        self.color = color
        self.text = text
        self.emoji = emoji
    }

    public static let colorNames = ["gray", "red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal",
                                    "cyan", "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose"]

    /// Matches T3's ProjectMonogram default, including Unicode normalization,
    /// digits in names, and the deterministic 18-color hash.
    public static func fallback(projectName: String) -> Self {
        let normalized = projectName.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")
        let words = regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).compactMap {
            Range($0.range, in: normalized).map { String(normalized[$0]) }
        }
        let monogram: String
        if let first = words.first {
            let letters = Array(first.unicodeScalars)
            let initial = letters[0]
            let digit = letters.dropFirst().first { String($0).range(of: "\\p{N}", options: .regularExpression) != nil }
            let second = digit ?? (words.count > 1 ? words.last?.unicodeScalars.first : letters.last) ?? initial
            monogram = String(String(initial).appending(String(second)).uppercased().unicodeScalars.prefix(2))
        } else { monogram = "PR" }
        let hashName = normalized.lowercased(with: Locale(identifier: "en_US"))
        let hash = (hashName.isEmpty ? "project" : hashName).unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % colorNames.count }
        return Self(kind: "monogram", color: colorNames[hash], text: monogram)
    }
}

public struct T3Project: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var workspaceRoot: String
    public var projectIcon: T3ProjectIcon?
    public var faviconPath: String?

    public init(id: String, title: String, workspaceRoot: String, projectIcon: T3ProjectIcon? = nil, faviconPath: String? = nil) {
        self.id = id
        self.title = title
        self.workspaceRoot = workspaceRoot
        self.projectIcon = projectIcon
        self.faviconPath = faviconPath
    }
}

public struct T3ModelSelection: Codable, Equatable, Sendable {
    public var model: String
    public var instanceId: String?

    public init(model: String, instanceId: String? = nil) {
        self.model = model
        self.instanceId = instanceId
    }
}

public struct T3Message: Codable, Equatable, Sendable {
    public var id: String?
    public var role: String
    public var text: String
    public var updatedAt: String?

    public init(id: String? = nil, role: String, text: String, updatedAt: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.updatedAt = updatedAt
    }
}

public struct T3PendingRequest: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var createdAt: String
    public var userOnly: Bool?
    public var blocking: Bool?

    public init(id: String, kind: String, createdAt: String, userOnly: Bool? = nil, blocking: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.userOnly = userOnly
        self.blocking = blocking
    }
}

public struct T3ThreadLineage: Codable, Equatable, Sendable {
    public var relationshipToParent: String?
    public var sideChat: Bool?
    public init(relationshipToParent: String? = nil, sideChat: Bool? = nil) {
        self.relationshipToParent = relationshipToParent
        self.sideChat = sideChat
    }
}

public struct T3BackgroundTask: Codable, Equatable, Sendable {
    public var taskId: String
    public var kind: String
    public var awaited: Bool?

    public init(taskId: String, kind: String, awaited: Bool? = nil) {
        self.taskId = taskId
        self.kind = kind
        self.awaited = awaited
    }

    /// T3 does not hold completion for an unawaited server/monitor left running.
    public var holdsCompletion: Bool { awaited == true || !["command", "monitor"].contains(kind) }
}

public struct T3Thread: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var projectId: String
    public var status: String
    public var activeRunId: String?
    public var activityRunStatus: String?
    public var blockedOnThreadWait: Bool?
    public var pendingBackgroundTasks: [T3BackgroundTask]?
    public var latestRunBackgroundWake: Bool?
    public var latestRunId: String?
    public var latestRunCompletedAt: String?
    public var lastVisitedAt: String?
    public var updatedAt: String
    public var archivedAt: String?
    public var settledAt: String?
    public var settledOverride: String?
    public var lineage: T3ThreadLineage?
    public var snoozedUntil: String?
    public var snoozedAt: String?
    public var deletedAt: String?
    public var pendingRuntimeRequest: T3PendingRequest?
    public var latestVisibleMessage: T3Message?
    public var modelSelection: T3ModelSelection?
    public var worktreePath: String?

    public init(id: String, title: String, projectId: String, status: String, activeRunId: String? = nil, latestRunId: String? = nil, updatedAt: String, archivedAt: String? = nil, settledAt: String? = nil, deletedAt: String? = nil, pendingRuntimeRequest: T3PendingRequest? = nil, latestVisibleMessage: T3Message? = nil, modelSelection: T3ModelSelection? = nil, worktreePath: String? = nil, settledOverride: String? = nil, lineage: T3ThreadLineage? = nil, snoozedUntil: String? = nil, snoozedAt: String? = nil, latestRunCompletedAt: String? = nil, lastVisitedAt: String? = nil, activityRunStatus: String? = nil, blockedOnThreadWait: Bool? = nil, pendingBackgroundTasks: [T3BackgroundTask]? = nil, latestRunBackgroundWake: Bool? = nil) {
        self.id = id
        self.title = title
        self.projectId = projectId
        self.status = status
        self.activeRunId = activeRunId
        self.activityRunStatus = activityRunStatus
        self.blockedOnThreadWait = blockedOnThreadWait
        self.pendingBackgroundTasks = pendingBackgroundTasks
        self.latestRunBackgroundWake = latestRunBackgroundWake
        self.latestRunId = latestRunId
        self.latestRunCompletedAt = latestRunCompletedAt
        self.lastVisitedAt = lastVisitedAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.settledAt = settledAt
        self.settledOverride = settledOverride
        self.lineage = lineage
        self.snoozedUntil = snoozedUntil
        self.snoozedAt = snoozedAt
        self.deletedAt = deletedAt
        self.pendingRuntimeRequest = pendingRuntimeRequest
        self.latestVisibleMessage = latestVisibleMessage
        self.modelSelection = modelSelection
        self.worktreePath = worktreePath
    }

    /// The latest run can be completed while this thread still waits on work.
    /// Match T3's native activity and background-completion holding rules.
    public var isWorking: Bool {
        if let activityRunStatus, !activityRunStatus.isEmpty { return true }
        if let activeRunId, !activeRunId.isEmpty { return true }
        if ["running", "starting", "queued", "preparing", "waiting"].contains(status) || blockedOnThreadWait == true { return true }
        guard status != "failed" else { return false }
        let tasks = pendingBackgroundTasks ?? []
        if tasks.contains(where: \.holdsCompletion) { return true }
        return latestRunBackgroundWake == true && tasks.contains {
            $0.kind == "monitor" && !$0.taskId.hasPrefix("pull-request-watch:")
        }
    }

    public var effectiveActivityStatus: String {
        if let activityRunStatus, !activityRunStatus.isEmpty { return activityRunStatus }
        if isWorking && !["running", "starting", "queued", "preparing", "waiting"].contains(status) { return "waiting" }
        return status
    }
}

public struct T3ShellSnapshot: Codable, Equatable, Sendable {
    public var threads: [T3Thread]
    public var projects: [T3Project]
    public var snapshotSequence: Int

    public init(threads: [T3Thread], projects: [T3Project], snapshotSequence: Int) {
        self.threads = threads
        self.projects = projects
        self.snapshotSequence = snapshotSequence
    }
}

public struct T3ResponseCapability: Codable, Equatable, Sendable {
    public var type: String
    public var reason: String?

    public init(type: String, reason: String? = nil) {
        self.type = type
        self.reason = reason
    }
}

public struct T3RuntimeRequest: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var status: String
    public var responseCapability: T3ResponseCapability

    public init(id: String, kind: String, status: String, responseCapability: T3ResponseCapability) {
        self.id = id
        self.kind = kind
        self.status = status
        self.responseCapability = responseCapability
    }
}

public struct T3QuestionOption: Codable, Equatable, Sendable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct T3Question: Codable, Equatable, Sendable {
    public var id: String
    public var header: String?
    public var question: String
    public var options: [T3QuestionOption]?
    public var multiSelect: Bool?
    public var isSecret: Bool?

    public init(id: String, header: String? = nil, question: String, options: [T3QuestionOption]? = nil, multiSelect: Bool? = nil, isSecret: Bool? = nil) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.isSecret = isSecret
    }
}

public struct T3ApprovalOption: Codable, Equatable, Sendable {
    public var decision: String
    public var label: String
    public var warning: String?

    public init(decision: String, label: String, warning: String? = nil) {
        self.decision = decision
        self.label = label
        self.warning = warning
    }
}

public struct T3TurnItem: Codable, Equatable, Sendable {
    public var id: String?
    public var type: String
    public var requestId: String?
    public var prompt: String?
    public var reason: String?
    public var input: String?
    public var text: String?
    public var questions: [T3Question]?
    public var options: [T3ApprovalOption]?

    public init(id: String? = nil, type: String, requestId: String? = nil, prompt: String? = nil, reason: String? = nil, input: String? = nil, text: String? = nil, questions: [T3Question]? = nil, options: [T3ApprovalOption]? = nil) {
        self.id = id
        self.type = type
        self.requestId = requestId
        self.prompt = prompt
        self.reason = reason
        self.input = input
        self.text = text
        self.questions = questions
        self.options = options
    }
    private enum CodingKeys: String, CodingKey { case id, type, requestId, prompt, reason, input, text, questions, options }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        input = try? container.decodeIfPresent(String.self, forKey: .input)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        questions = try container.decodeIfPresent([T3Question].self, forKey: .questions)
        options = try container.decodeIfPresent([T3ApprovalOption].self, forKey: .options)
    }

}

public struct T3ThreadDetail: Decodable, Equatable, Sendable {
    public var messages: [T3Message]
    public var runtimeRequests: [T3RuntimeRequest]
    public var turnItems: [T3TurnItem]
    public init(messages: [T3Message] = [], runtimeRequests: [T3RuntimeRequest] = [], turnItems: [T3TurnItem] = []) {
        self.messages = messages
        self.runtimeRequests = runtimeRequests
        self.turnItems = turnItems
    }
    private enum CodingKeys: String, CodingKey { case projection }
    private enum ProjectionKeys: String, CodingKey { case messages, runtimeRequests, turnItems }
    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        let projection = try root.nestedContainer(keyedBy: ProjectionKeys.self, forKey: .projection)
        messages = try projection.decode([T3Message].self, forKey: .messages)
        runtimeRequests = try projection.decode([T3RuntimeRequest].self, forKey: .runtimeRequests)
        turnItems = try projection.decode([T3TurnItem].self, forKey: .turnItems)
    }
}

public enum T3ShellEvent: Equatable, Sendable {
    case snapshot(T3ShellSnapshot)
    case threadUpdated(T3Thread)
    case threadRemoved(String)
    case snapshotRequired
    case projectUpdated(T3Project)
    case projectRemoved(String)
    /// Partial repository-identity refresh: upsert these projects without replacing threads.
    case projectEnrichment(projects: [T3Project], resolvedRoots: [String])
}
