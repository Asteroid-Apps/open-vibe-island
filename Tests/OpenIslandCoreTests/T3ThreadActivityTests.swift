import Foundation
import Testing
@testable import OpenIslandCore

struct T3ThreadActivityTests {
    private func completed() -> T3Thread {
        T3Thread(id: "thread", title: "Thread", projectId: "p", status: "completed", updatedAt: "2026-11-24T18:00:00Z")
    }

    @Test func activeWorkTakesPrecedenceOverLatestCompletedRun() {
        var thread = completed()
        thread.activityRunStatus = "waiting"
        #expect(thread.isWorking)
        #expect(thread.effectiveActivityStatus == "waiting")
        thread.activityRunStatus = nil
        thread.blockedOnThreadWait = true
        #expect(thread.isWorking)
        thread.blockedOnThreadWait = nil
        thread.activeRunId = "older-active-run"
        #expect(thread.isWorking)
        thread.activeRunId = nil
        thread.status = "waiting"
        #expect(thread.isWorking)
        thread.status = "completed"
        #expect(!thread.isWorking)
    }

    @Test func awaitedCommandsAndSubagentsHoldCompletionButPersistentServersDoNot() {
        var thread = completed()
        for task in [
            T3BackgroundTask(taskId: "child", kind: "subagent"),
            T3BackgroundTask(taskId: "work", kind: "background_task"),
            T3BackgroundTask(taskId: "command", kind: "command", awaited: true),
            T3BackgroundTask(taskId: "future", kind: "future_background_kind")
        ] {
            thread.pendingBackgroundTasks = [task]
            #expect(thread.isWorking)
            #expect(thread.effectiveActivityStatus == "waiting")
        }
        thread.pendingBackgroundTasks = [T3BackgroundTask(taskId: "dev-server", kind: "command")]
        #expect(!thread.isWorking)
        thread.pendingBackgroundTasks = []
        #expect(!thread.isWorking)
        #expect(thread.effectiveActivityStatus == "completed")
    }

    @Test func progressMonitorWakeHoldsCompletionButPassiveWatchesAndFailuresDoNot() {
        var thread = completed()
        thread.pendingBackgroundTasks = [T3BackgroundTask(taskId: "monitor:work", kind: "monitor")]
        #expect(!thread.isWorking)
        thread.latestRunBackgroundWake = true
        #expect(thread.isWorking)
        thread.pendingBackgroundTasks = [T3BackgroundTask(taskId: "pull-request-watch:repo#1", kind: "monitor")]
        #expect(!thread.isWorking)
        thread.status = "failed"
        thread.pendingBackgroundTasks = [T3BackgroundTask(taskId: "child", kind: "subagent")]
        #expect(!thread.isWorking)
    }

    @Test func decodesNativeActivityAndWaitingWorkWithoutBreakingOlderServers() throws {
        let data = Data(#"""
        {"id":"thread","title":"Thread","projectId":"p","status":"completed","updatedAt":"2026-11-24T18:00:00Z",
         "activityRunStatus":"waiting","blockedOnThreadWait":true,"latestRunBackgroundWake":true,
         "pendingBackgroundTasks":[{"taskId":"child","kind":"subagent","childThreadId":"hidden-child"},
                                   {"taskId":"command","kind":"command","awaited":true}]}
        """#.utf8)
        let thread = try JSONDecoder().decode(T3Thread.self, from: data)
        #expect(thread.activityRunStatus == "waiting")
        #expect(thread.blockedOnThreadWait == true)
        #expect(thread.latestRunBackgroundWake == true)
        #expect(thread.pendingBackgroundTasks?.count == 2)
        #expect(thread.isWorking)
        #expect(try JSONDecoder().decode(T3Thread.self, from: JSONEncoder().encode(thread)) == thread)
        let legacy = try JSONDecoder().decode(T3Thread.self, from: Data(#"{"id":"thread","title":"Thread","projectId":"p","status":"completed","updatedAt":"now"}"#.utf8))
        #expect(!legacy.isWorking)
        #expect(legacy.pendingBackgroundTasks == nil)
    }
}
