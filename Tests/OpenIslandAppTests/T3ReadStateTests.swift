import Foundation
import AppKit
import ApplicationServices
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct T3ReadStateTests {
    @Test func liveFocusedDesktopChatIdentity() throws {
        guard let expectedURL = ProcessInfo.processInfo.environment["OPEN_ISLAND_TEST_T3_FOREGROUND_URL"] else { return }
        try #require(AXIsProcessTrusted(), "The live probe requires Accessibility access for its host process.")
        try #require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.t3tools.t3code", "T3 Code must be frontmost during the live probe.")
        let expected = try #require(T3ForegroundThread(url: URL(string: expectedURL)!))
        #expect(T3ForegroundThread.current() == expected)
    }

    @Test func completionStaysDoneUntilViewedAndANewRunBecomesUnreadAgain() throws {
        var foreground: T3ForegroundThread?
        let coordinator = T3CodeCoordinator(foregroundThread: { foreground })
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://localhost:3773")!))
        var state = SessionState()
        var completions = 0
        coordinator.onEvent = {
            state.apply($0)
            if case .sessionCompleted = $0 { completions += 1 }
        }
        coordinator.isSessionTracked = { state.session(id: $0) != nil }
        var thread = T3Thread(id: "thread", title: "Read state", projectId: "project", status: "running",
                              activeRunId: "run-1", latestRunId: "run-1", updatedAt: "2020-01-01T18:00:00Z",
                              lastVisitedAt: "2020-01-01T17:59:00Z")
        coordinator.applyThread(thread, detail: nil)
        thread.status = "completed"
        thread.activeRunId = nil
        thread.latestRunCompletedAt = "2020-01-01T18:00:00.000Z"
        coordinator.applyThread(thread, detail: nil)
        let id = "t3:local:thread"
        let surface = IslandSurface.sessionList(actionableSessionID: id)
        var session = try #require(state.session(id: id))
        #expect(session.spotlightStatusLabel == "Completed")
        #expect(session.islandPresence(at: .now) == .active)
        #expect(surface.matchesCurrentState(of: session))

        thread.lastVisitedAt = "2020-01-01T18:00:01Z"
        foreground = T3ForegroundThread(url: URL(string: "t3code://app/#/local/thread")!)
        thread.updatedAt = "2020-01-01T18:00:01Z"
        coordinator.applyThread(thread, detail: nil)
        session = try #require(state.session(id: id))
        #expect(session.spotlightStatusLabel == "Idle")
        #expect(session.islandPresence(at: .now) == .inactive)
        #expect(session.isVisibleInIsland)
        #expect(!surface.matchesCurrentState(of: session))
        #expect(completions == 1)

        thread.status = "running"
        foreground = nil
        thread.activeRunId = "run-2"
        thread.latestRunId = "run-2"
        coordinator.applyThread(thread, detail: nil)
        session = try #require(state.session(id: id))
        #expect(session.phase == .running)
        #expect(session.islandPresence(at: .now) == .running)
        thread.status = "completed"
        thread.activeRunId = nil
        thread.latestRunCompletedAt = "2020-01-01T18:05:00Z"
        coordinator.applyThread(thread, detail: nil)
        session = try #require(state.session(id: id))
        #expect(session.spotlightStatusLabel == "Completed")
        #expect(surface.matchesCurrentState(of: session))
        #expect(completions == 2)

        // Equal timestamps acknowledge the result too; ISO precision may differ.
        thread.lastVisitedAt = "2020-01-01T18:05:00.000Z"
        foreground = T3ForegroundThread(url: URL(string: "t3code://app/#/local/thread")!)
        coordinator.applyThread(thread, detail: nil)
        #expect(state.session(id: id)?.spotlightStatusLabel == "Idle")
        #expect(completions == 2)
    }

    @Test func backgroundAutoVisitDoesNotAcknowledgeAndFocusOnlyClearsTheVisibleChat() throws {
        var foreground: T3ForegroundThread?
        let coordinator = T3CodeCoordinator(foregroundThread: { foreground })
        coordinator.receiveConnection(T3ConnectionInfo(environmentID: "local", origin: URL(string: "http://localhost:3773")!))
        var state = SessionState()
        var completions = 0
        coordinator.onEvent = {
            state.apply($0)
            if case .sessionCompleted = $0 { completions += 1 }
        }
        coordinator.isSessionTracked = { state.session(id: $0) != nil }
        var thread = T3Thread(id: "thread", title: "Background", projectId: "project", status: "running",
                              activeRunId: "run", latestRunId: "run", updatedAt: "2026-11-24T18:00:00Z")
        coordinator.applyThread(thread, detail: nil)
        thread.status = "completed"
        thread.activeRunId = nil
        thread.latestRunCompletedAt = "2026-11-24T18:01:00Z"
        thread.lastVisitedAt = "2026-11-24T18:01:00Z"
        coordinator.applyThread(thread, detail: nil)
        let id = "t3:local:thread"
        #expect(state.session(id: id)?.t3Metadata?.hasUnreadCompletion == true)
        thread.lastVisitedAt = "2026-11-24T18:02:00Z"
        coordinator.applyThread(thread, detail: nil)
        coordinator.refreshForegroundReadState()
        #expect(state.session(id: id)?.t3Metadata?.hasUnreadCompletion == true)

        for route in ["local/other", "remote/thread"] {
            foreground = T3ForegroundThread(url: URL(string: "t3code://app/#/\(route)")!)
            coordinator.refreshForegroundReadState()
            #expect(state.session(id: id)?.t3Metadata?.hasUnreadCompletion == true)
        }
        // No new visit event is required when returning to the already-selected chat.
        foreground = T3ForegroundThread(url: URL(string: "t3code://app/#/local/thread")!)
        coordinator.refreshForegroundReadState()
        #expect(state.session(id: id)?.spotlightStatusLabel == "Idle")
        foreground = nil
        coordinator.applyThread(thread, detail: nil)
        #expect(state.session(id: id)?.t3Metadata?.hasUnreadCompletion == false)
        #expect(completions == 1)
    }

    @Test func historicalReadCompletionsStayIdleOnInitialSnapshot() {
        let coordinator = T3CodeCoordinator(foregroundThread: { nil })
        var state = SessionState()
        coordinator.onEvent = { state.apply($0) }
        let thread = T3Thread(id: "thread", title: "History", projectId: "project", status: "completed",
                              updatedAt: "2026-11-24T18:00:00Z", latestRunCompletedAt: "2026-11-24T17:00:00Z",
                              lastVisitedAt: "2026-11-24T18:00:00Z")
        coordinator.applyThread(thread, detail: nil)
        #expect(state.sessions.first?.spotlightStatusLabel == "Idle")
    }

    @Test func foregroundRoutesRequireAnExactDesktopChatURL() {
        let thread = T3ForegroundThread(url: URL(string: "t3code://app/#/remote/thread")!)
        #expect(thread?.environmentID == "remote")
        #expect(thread?.threadID == "thread")
        for url in ["https://example.com/#/remote/thread", "t3code://app/#/", "t3code://app/#/remote/thread/settings"] {
            #expect(T3ForegroundThread(url: URL(string: url)!) == nil)
        }
    }

    @Test func unknownCompletionOrVisitTimesDoNotClearUnreadResults() {
        for (completed, visited) in [(nil, nil), ("bad", "2026-11-24T18:00:00Z"), ("2026-11-24T18:00:00Z", "bad"), ("2026-11-24T18:00:00Z", nil)] as [(String?, String?)] {
            let coordinator = T3CodeCoordinator()
            var state = SessionState()
            coordinator.onEvent = { state.apply($0) }
            let thread = T3Thread(id: "thread", title: "Unknown read state", projectId: "project", status: "completed", updatedAt: "2026-11-24T18:00:00Z", latestRunCompletedAt: completed, lastVisitedAt: visited)
            coordinator.applyThread(thread, detail: nil)
            #expect(state.sessions.first?.t3Metadata?.hasUnreadCompletion == true)
            #expect(state.sessions.first?.spotlightStatusLabel == "Completed")
        }
    }
}
