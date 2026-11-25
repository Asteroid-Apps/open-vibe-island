import Foundation
import Testing
@testable import OpenIslandCore

struct T3SessionStateTests {
    @Test func nativeLivenessAndMetadataSurviveTerminalPolling() throws {
        let now = Date()
        var state = SessionState()
        state.apply(.sessionStarted(SessionStarted(
            sessionID: "t3:local:thread", title: "T3 Code · example", tool: .t3Code,
            origin: .live, summary: "Working", timestamp: now,
            t3Metadata: T3SessionMetadata(lastUserPrompt: "Fix the bug")
        )))
        _ = state.markProcessLiveness(aliveSessionIDs: [])
        _ = state.markProcessLiveness(aliveSessionIDs: [])
        #expect(state.session(id: "t3:local:thread")?.isSessionEnded == false)
        #expect(state.session(id: "t3:local:thread")?.isVisibleInIsland == true)

        let event = AgentEvent.t3SessionMetadataUpdated(T3SessionMetadataUpdated(
            sessionID: "t3:local:thread",
            t3Metadata: T3SessionMetadata(lastAssistantMessage: "Fixed", lastUserPrompt: "Fix the bug"),
            timestamp: now
        ))
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
        state.apply(decoded)
        #expect(state.session(id: "t3:local:thread")?.lastAssistantMessageText == "Fixed")
        _ = state.reconcileAttachmentStates(["t3:local:thread": .stale])
        #expect(state.session(id: "t3:local:thread")?.isVisibleInIsland == false)
        _ = state.removeInvisibleSessions()
        #expect(state.session(id: "t3:local:thread") != nil)
        _ = state.reconcileAttachmentStates(["t3:local:thread": .attached])
        #expect(state.session(id: "t3:local:thread")?.isVisibleInIsland == true)
    }
}
