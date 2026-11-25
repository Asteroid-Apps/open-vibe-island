import Foundation

public enum T3CodeError: Error, LocalizedError, Sendable {
    case unavailable, invalidLocalRuntime, authenticationFailed, disconnected, invalidResponse, requestFailed
    public var errorDescription: String? {
        switch self {
        case .unavailable: "T3 Code is not running locally."
        case .invalidLocalRuntime: "T3 Code's runtime must use a loopback HTTP address."
        case .authenticationFailed: "Could not create a scoped T3 Code session."
        case .disconnected: "T3 Code is disconnected."
        case .invalidResponse: "T3 Code returned an unsupported response."
        case .requestFailed: "T3 Code could not complete the request."
        }
    }
}

// Do not forward a local bearer credential through an HTTP redirect.
private final class T3SessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Native T3 client. Local credentials are scoped, short-lived, and revoked on
/// disconnect. Saved desktop credentials are borrowed in memory and never revoked.
/// No provider credentials or T3 database reads are needed.
public actor T3CodeClient {
    private let savedEnvironment: T3SavedEnvironment?
    private let home: URL
    private let cliURL: URL
    private let session: URLSession
    private var info: T3ConnectionInfo?
    private var token: String?
    private var sessionID: String?
    private var expiresAt: Date?
    private var generation = 0
    private var sockets: [UUID: URLSessionWebSocketTask] = [:]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3"), cliURL: URL? = nil, savedEnvironment: T3SavedEnvironment? = nil) {
        self.savedEnvironment = savedEnvironment
        self.home = home
        self.cliURL = cliURL ?? home.appendingPathComponent("bin/t3")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration, delegate: T3SessionDelegate(), delegateQueue: nil)
    }

    public static func validateLocalOrigin(_ origin: URL) throws {
        guard origin.scheme == "http", ["127.0.0.1", "localhost", "[::1]", "::1"].contains(origin.host ?? ""),
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/" else { throw T3CodeError.invalidLocalRuntime }
    }

    public func connect() async throws -> T3ConnectionInfo {
        await disconnect()
        generation += 1
        let connectingGeneration = generation
        if let savedEnvironment {
            try T3EnvironmentCatalog.validate(origin: savedEnvironment.origin, webSocketOrigin: savedEnvironment.webSocketOrigin)
            guard !savedEnvironment.bearerToken.isEmpty else { throw T3CodeError.authenticationFailed }
            token = savedEnvironment.bearerToken
            // The desktop owns this credential's lifetime and refreshes it in
            // its catalog. It must never be revoked by our disconnect path.
            expiresAt = .distantFuture
            let result = T3ConnectionInfo(environmentID: savedEnvironment.environmentID, origin: savedEnvironment.origin)
            info = result
            return result
        }
        struct Runtime: Decodable { let origin: URL; let pid: Int32 }
        guard let data = try? Data(contentsOf: home.appendingPathComponent("userdata/server-runtime.json")),
              let runtime = try? JSONDecoder().decode(Runtime.self, from: data),
              runtime.pid > 0, kill(runtime.pid, 0) == 0 else { throw T3CodeError.unavailable }
        try Self.validateLocalOrigin(runtime.origin)
        let environmentID = try String(contentsOf: home.appendingPathComponent("userdata/environment-id"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !environmentID.isEmpty else { throw T3CodeError.invalidLocalRuntime }
        let dataIssued = try await runCLI(["auth", "session", "issue", "--scope", "orchestration:read", "--scope", "orchestration:operate", "--ttl", "1h", "--label", "Open Island", "--json"])
        struct Issued: Decodable { let token: String; let sessionId: String; let expiresAt: String }
        guard let issued = try? JSONDecoder().decode(Issued.self, from: dataIssued) else { throw T3CodeError.authenticationFailed }
        guard generation == connectingGeneration, !Task.isCancelled else {
            _ = try? await runCLI(["auth", "session", "revoke", issued.sessionId])
            throw T3CodeError.disconnected
        }
        guard !issued.token.isEmpty, let expiration = ISO8601DateFormatter.t3Date(issued.expiresAt), expiration > Date() else { throw T3CodeError.authenticationFailed }
        expiresAt = expiration
        token = issued.token
        sessionID = issued.sessionId
        let result = T3ConnectionInfo(environmentID: environmentID, origin: runtime.origin)
        info = result
        return result
    }

    public func disconnect() async {
        generation += 1
        for socket in sockets.values { socket.cancel(with: .goingAway, reason: nil) }
        sockets.removeAll()
        let oldID = sessionID
        token = nil
        sessionID = nil
        expiresAt = nil
        info = nil
        if let oldID { _ = try? await runCLI(["auth", "session", "revoke", oldID]) }
    }

    private func runCLI(_ arguments: [String]) async throws -> Data {
        let executable = cliURL
        let baseDirectory = home.path
        let process = Process()
        let worker = Task.detached {
            try Task.checkCancellation()
            process.executableURL = executable
            process.arguments = arguments + ["--base-dir", baseDirectory]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw T3CodeError.authenticationFailed }
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
            let killWatchdog = DispatchWorkItem {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 17, execute: killWatchdog)
            defer { watchdog.cancel(); killWatchdog.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw T3CodeError.authenticationFailed }
            return data
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            if process.isRunning { process.terminate() }
        }
    }

    private func request(path: String) throws -> URLRequest {
        guard let info, let token else { throw T3CodeError.disconnected }
        var request = URLRequest(url: info.origin.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2", forHTTPHeaderField: "x-t3-orchestration-protocol")
        return request
    }

    private func ensureFreshSession() async throws {
        guard let expiresAt else { throw T3CodeError.disconnected }
        if expiresAt.timeIntervalSinceNow < 60 { _ = try await connect() }
    }

    public func snapshot() async throws -> T3ShellSnapshot {
        try await ensureFreshSession()
        let (data, response) = try await session.data(for: request(path: "api/orchestration/shell"))
        try Self.check(response)
        return try JSONDecoder().decode(T3ShellSnapshot.self, from: data)
    }

    public func threadDetail(threadID: String) async throws -> T3ThreadDetail {
        try await ensureFreshSession()
        var detailRequest = try request(path: "api/orchestration/threads")
        detailRequest.url = try Self.threadDetailURL(base: detailRequest.url!, threadID: threadID)
        let (data, response) = try await session.data(for: detailRequest)
        try Self.check(response)
        return try JSONDecoder().decode(T3ThreadDetail.self, from: data)
    }

    /// T3 identifiers can contain percent escapes and slashes (delegated runs).
    /// Encode the identifier as exactly one route segment without normalizing it.
    static func threadDetailURL(base: URL, threadID: String) throws -> URL {
        guard !threadID.isEmpty, threadID != ".", threadID != ".." else { throw T3CodeError.invalidResponse }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = threadID.addingPercentEncoding(withAllowedCharacters: allowed),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw T3CodeError.invalidResponse }
        components.percentEncodedPath += "/" + encoded
        guard let url = components.url else { throw T3CodeError.invalidResponse }
        return url
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw T3CodeError.requestFailed }
    }

    private func socket() async throws -> (UUID, URLSessionWebSocketTask) {
        try await ensureFreshSession()
        var request = try request(path: "ws")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        if let savedEnvironment {
            components = URLComponents(url: savedEnvironment.webSocketOrigin.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        } else {
            components.scheme = components.scheme == "https" ? "wss" : "ws"
        }
        components.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        request.url = components.url
        let socket = session.webSocketTask(with: request)
        let id = UUID()
        sockets[id] = socket
        socket.resume()
        return (id, socket)
    }

    private func closeSocket(_ id: UUID) {
        sockets.removeValue(forKey: id)?.cancel(with: .normalClosure, reason: nil)
    }

    private static func frame(tag: String, payload: CodexHookJSONValue) throws -> URLSessionWebSocketTask.Message {
        let value: CodexHookJSONValue = .object(["_tag": .string("Request"), "id": .string("1"), "tag": .string(tag), "payload": payload, "headers": .array([])])
        return .string(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }

    private static func decodeFrame(_ message: URLSessionWebSocketTask.Message) throws -> CodexHookJSONValue {
        let data: Data
        switch message {
        case let .data(value): data = value
        case let .string(value): data = Data(value.utf8)
        @unknown default: throw T3CodeError.invalidResponse
        }
        return try JSONDecoder().decode(CodexHookJSONValue.self, from: data)
    }

    public func shellEvents() async throws -> AsyncThrowingStream<T3ShellEvent, Error> {
        let (id, socket) = try await socket()
        try await socket.send(Self.frame(tag: "orchestration.subscribeShell", payload: .object([:])))
        return AsyncThrowingStream { continuation in
            // Reconnect before the one-hour credential expires, even on an idle server.
            let renewal = Task {
                try? await Task.sleep(for: .seconds(50 * 60))
                if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
            }
            let task = Task {
                defer { renewal.cancel() }
                do {
                    while !Task.isCancelled {
                        let frame = try Self.decodeFrame(try await socket.receive())
                        if frame.t3String("_tag") == "Ping" { try await socket.send(.string("{\"_tag\":\"Pong\"}")); continue }
                        if frame.t3String("_tag") == "Chunk" {
                            for item in frame.t3Array("values") {
                                if let event = try Self.shellEvent(item) { continuation.yield(event) }
                            }
                            try await socket.send(.string("{\"_tag\":\"Ack\",\"requestId\":\"1\"}"))
                        } else if frame.t3String("_tag") == "Exit" { throw T3CodeError.requestFailed }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
                self.closeSocket(id)
            }
            continuation.onTermination = { _ in task.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        }
    }

    public static func shellEvent(_ value: CodexHookJSONValue) throws -> T3ShellEvent? {
        func decode<T: Decodable>(_ key: String, as: T.Type) throws -> T {
            guard let value = value.t3Object[key] else { throw T3CodeError.invalidResponse }
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        }
        switch value.t3String("kind") {
        case "snapshot":
            let snapshot = try decode("snapshot", as: T3ShellSnapshot.self)
            // T3 emits a second snapshot containing only resolved project identities
            // after its authoritative shell snapshot (and on later enrichment).
            // Its empty thread lists are placeholders, never a removal signal.
            if value.t3Object["resolvedRepositoryIdentityRoots"] != nil,
               snapshot.threads.isEmpty,
               value.t3Object["snapshot"]?.t3Array("archivedThreads").isEmpty == true {
                return .projectEnrichment(projects: snapshot.projects,
                                          resolvedRoots: try decode("resolvedRepositoryIdentityRoots", as: [String].self))
            }
            return .snapshot(snapshot)
        case "thread.updated": return .threadUpdated(try decode("thread", as: T3Thread.self))
        case "thread.removed": guard let id = value.t3String("threadId") else { throw T3CodeError.invalidResponse }; return .threadRemoved(id)
        case "project.updated": return .projectUpdated(try decode("project", as: T3Project.self))
        case "project.removed": guard let id = value.t3String("projectId") else { throw T3CodeError.invalidResponse }; return .projectRemoved(id)
        case "snapshot-required": return .snapshotRequired
        default: return nil
        }
    }

    private func rpc(tag: String, payload: CodexHookJSONValue) async throws -> CodexHookJSONValue {
        let (id, socket) = try await socket()
        let deadline = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        defer { deadline.cancel(); closeSocket(id) }
        try await socket.send(Self.frame(tag: tag, payload: payload))
        while true {
            let frame = try Self.decodeFrame(try await socket.receive())
            if frame.t3String("_tag") == "Ping" { try await socket.send(.string("{\"_tag\":\"Pong\"}")); continue }
            guard frame.t3String("_tag") == "Exit" else { continue }
            guard frame.t3Object["exit"]?.t3String("_tag") == "Success" else { throw T3CodeError.requestFailed }
            return frame.t3Object["exit"]?.t3Object["value"] ?? .null
        }
    }

    private func dispatch(_ command: [String: CodexHookJSONValue]) async throws {
        var command = command
        command["commandId"] = .string(UUID().uuidString)
        _ = try await rpc(tag: "orchestration.dispatchCommand", payload: .object(command))
    }

    /// Uses T3's own favicon discovery and authenticated asset service, including
    /// remote projects. Never interprets a remote workspace path on this Mac.
    public func projectFavicon(_ project: T3Project) async throws -> Data? {
        var resource: [String: CodexHookJSONValue] = ["_tag": .string("project-favicon"), "cwd": .string(project.workspaceRoot)]
        if let path = project.faviconPath { resource["path"] = .string(path) }
        let result = try await rpc(tag: "assets.createUrl", payload: .object(["resource": .object(resource)]))
        guard let relative = result.t3String("relativeUrl"), relative.hasPrefix("/api/assets/") else {
            throw T3CodeError.invalidResponse
        }
        if relative.contains("project-favicon-missing") { return nil }
        guard let info, let url = URL(string: relative, relativeTo: info.origin)?.absoluteURL,
              url.scheme == info.origin.scheme, url.host == info.origin.host,
              url.port == info.origin.port else { throw T3CodeError.invalidResponse }
        var assetRequest = try request(path: "api/assets")
        assetRequest.url = url
        let (data, response) = try await session.data(for: assetRequest)
        try Self.check(response)
        guard data.count <= 2 * 1024 * 1024 else { throw T3CodeError.invalidResponse }
        return data.isEmpty ? nil : data
    }

    public func respond(threadID: String, requestID: String, decision: String? = nil, answers: [String: CodexHookJSONValue]? = nil) async throws {
        if let decision, !["accept", "acceptForSession", "acceptAlways", "decline", "cancel"].contains(decision) { throw T3CodeError.invalidResponse }
        var command: [String: CodexHookJSONValue] = ["type": .string("runtime-request.respond"), "threadId": .string(threadID), "requestId": .string(requestID)]
        if let decision { command["decision"] = .string(decision) }
        if let answers { command["answers"] = .object(answers) }
        try await dispatch(command)
    }

    public func sendMessage(threadID: String, text: String) async throws {
        try await dispatch(["type": .string("message.dispatch"), "threadId": .string(threadID), "messageId": .string(UUID().uuidString), "text": .string(text), "attachments": .array([]), "createdBy": .string("user"), "creationSource": .string("web"), "dispatchMode": .object(["type": .string("queue_after_active")])])
    }

    public func interrupt(threadID: String) async throws {
        try await dispatch(["type": .string("thread.stop"), "threadId": .string(threadID)])
    }
}

extension CodexHookJSONValue {
    var t3Object: [String: CodexHookJSONValue] { if case let .object(value) = self { value } else { [:] } }
    func t3String(_ key: String) -> String? { if case let .string(value) = t3Object[key] { value } else { nil } }
    func t3Array(_ key: String) -> [CodexHookJSONValue] { if case let .array(value) = t3Object[key] { value } else { [] } }
}

private extension ISO8601DateFormatter {
    static func t3Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
