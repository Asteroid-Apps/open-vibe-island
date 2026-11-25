import AppKit
import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

struct T3PresentationTests {
    private final class Arguments: @unchecked Sendable {
        var values: [[String]] = []
    }

    @Test
    func nativeJumpUsesEnvironmentAndEscapesThreadIdentity() throws {
        let arguments = Arguments()
        let service = TerminalJumpService(
            applicationResolver: { $0 == "com.t3tools.t3code" ? URL(fileURLWithPath: "/Applications/T3 Code (Beta).app") : nil },
            appRunningChecker: { $0 == "com.t3tools.t3code" },
            openAction: { arguments.values.append($0) },
            appleScriptRunner: { _ in "" }
        )
        let result = try service.jump(to: JumpTarget(
            terminalApp: "T3 Code", workspaceName: "Project", paneTitle: "Thread",
            t3ThreadID: "thread/with?query#fragment", t3EnvironmentID: "env id"
        ))
        #expect(result == "Focused the T3 Code conversation.")
        #expect(arguments.values == [["-b", "com.t3tools.t3code", "t3code://threads/env%20id/thread%2Fwith%3Fquery%23fragment"]])
    }

    @Test
    func nativeJumpWithoutIdentityActivatesDesktop() throws {
        let arguments = Arguments()
        let service = TerminalJumpService(
            applicationResolver: { $0 == "com.t3tools.t3code" ? URL(fileURLWithPath: "/Applications/T3 Code (Beta).app") : nil },
            appRunningChecker: { $0 == "com.t3tools.t3code" },
            openAction: { arguments.values.append($0) },
            appleScriptRunner: { _ in "" }
        )
        _ = try service.jump(to: JumpTarget(terminalApp: "T3 Code (Beta).app", workspaceName: "Project", paneTitle: "Thread"))
        #expect(arguments.values == [["-b", "com.t3tools.t3code"]])
    }

    @Test
    func nativeReplyNeedsCompletedThreadAndEnabledFeature() {
        var session = makeSession()
        #expect(TerminalTextSender.canReply(to: session, enabled: true))
        #expect(!TerminalTextSender.canReply(to: session, enabled: false))
        session.phase = .running
        #expect(!TerminalTextSender.canReply(to: session, enabled: true))
        session.phase = .completed
        session.attachmentState = .stale
        #expect(!TerminalTextSender.canReply(to: session, enabled: true))
        session.attachmentState = .attached
        session.jumpTarget?.t3EnvironmentID = nil
        #expect(!TerminalTextSender.canReply(to: session, enabled: true))
    }

    @Test
    func providerIndependentMetadataSurvivesSerializationAndFeedsPresentation() throws {
        let session = makeSession()
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
        #expect(decoded.latestUserPromptText == "Build it")
        #expect(decoded.initialUserPromptText == "Start here")
        #expect(decoded.completionAssistantMessageText == "Built it")
        #expect(decoded.currentToolName == "shell")
        #expect(decoded.completionReplyRecipientName == "T3 Code")
        #expect(decoded.spotlightShowsDetailLines(at: session.updatedAt))
    }

    @Test
    func disconnectedPendingNativeSessionsAreNotVisible() {
        var session = makeSession()
        session.phase = .waitingForApproval
        #expect(session.isVisibleInIsland)
        session.attachmentState = .stale
        #expect(!session.isVisibleInIsland)
        session.attachmentState = .attached
        session.isSessionEnded = true
        #expect(!session.isVisibleInIsland)
    }

    @Test
    func oldJumpTargetsStillDecodeWithoutNativeFields() throws {
        let json = Data(#"{"terminalApp":"Terminal","workspaceName":"Project","paneTitle":"shell"}"#.utf8)
        let target = try JSONDecoder().decode(JumpTarget.self, from: json)
        #expect(target.t3ThreadID == nil)
        #expect(target.t3EnvironmentID == nil)
    }

    @Test func assistantPreviewUsesMessagesInsteadOfCommandsOrStatus() {
        var session = makeSession()
        session.phase = .running
        session.summary = "Running a tool"
        session.t3Metadata?.currentTool = "shell command"
        session.t3Metadata?.lastAssistantMessage = "  I’m checking the query now.  "
        #expect(session.islandAssistantPreviewText == "I’m checking the query now.")
        session.t3Metadata?.lastAssistantMessage = "  \n "
        #expect(session.islandAssistantPreviewText == nil)
        session.phase = .completed
        #expect(session.islandAssistantPreviewText == nil)
    }

    @MainActor @Test func projectIconAssetsIncludeNativeLucideShapesAndLegacyNames() {
        for name in ["folder-code", "rocket", "database", "bot", "layers-3", "globe-2", "code-2", "gamepad-2"] {
            #expect(T3ProjectIconAssets.image(named: name) != nil, "Missing Lucide icon: \(name)")
        }
        #expect(T3ProjectIconAssets.image(named: "not-a-real-lucide-icon") == nil)
    }

    @MainActor @Test func projectVectorIconsHaveTransparentBackgroundsAndVisibleStrokes() throws {
        let image = try #require(T3ProjectIconAssets.image(named: "rocket"))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        let hasVisibleStroke = (0..<bitmap.pixelsHigh).contains { y in
            (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
        }
        #expect(hasVisibleStroke)
    }

    private func makeSession() -> AgentSession {
        AgentSession(
            id: "t3:env:thread", title: "T3 Code · Project", tool: .t3Code,
            origin: .live, attachmentState: .attached, phase: .completed,
            summary: "Built it", updatedAt: Date(),
            jumpTarget: JumpTarget(terminalApp: "T3 Code", workspaceName: "Project", paneTitle: "Thread", t3ThreadID: "thread", t3EnvironmentID: "env"),
            t3Metadata: T3SessionMetadata(lastAssistantMessage: "Built it", lastUserPrompt: "Build it", initialUserPrompt: "Start here", currentTool: "shell", model: "provider-model")
        )
    }
}
