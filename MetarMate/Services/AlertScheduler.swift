import Foundation
import BackgroundTasks
import SwiftData

// MARK: - AlertScheduler
// Background-task plumbing for the weather-alert checks. On wake it runs the EXACT same
// AlertPipeline.runChecks the manual "Check now" uses — no divergent logic — then reschedules.
//
// `taskIdentifier` is the single source of truth, referenced by both register() and schedule()
// below. It MUST stay byte-for-byte identical to the BGTaskSchedulerPermittedIdentifiers entry
// in Info.plist; any drift makes the task silently never run (the classic background-task bug).
// Keeping it as one constant means the two Swift call sites can't disagree — only the Info.plist
// literal is hand-typed, and it's verified against this value.
enum AlertScheduler {
    static let taskIdentifier = "com.jeffquayle.MetarMate.alertcheck"

    // Register the launch handler. Must be called once at launch BEFORE launch completes
    // (from App.init), so the system can hand back a task it scheduled while the app was dead.
    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: refreshTask, container: container)
        }
    }

    // Submit a request for the next check. iOS decides the actual time; earliestBeginDate is
    // only a floor. Submitting again with the same identifier replaces any pending request, so
    // calling this repeatedly (launch, backgrounding, after each run) is safe.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)   // ~15 min floor
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[AlertScheduler] schedule submit failed: \(error.localizedDescription)")
        }
    }

    private static func handle(task: BGAppRefreshTask, container: ModelContainer) {
        // Reschedule the next cycle first, so a single run always sets up the next one even if
        // it's later cancelled by expiration.
        schedule()

        let work = Task { @MainActor in
            await AlertPipeline.runChecks(in: container.mainContext)
        }
        // iOS gives a limited window; if it expires, cancel the in-flight work.
        task.expirationHandler = { work.cancel() }

        Task {
            _ = await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }
}
