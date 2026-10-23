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
//
// nonisolated (audit #26): BGTaskScheduler calls the launch and expiration handlers on its own
// background queue. Under the target's MainActor default they'd be MainActor code running off the
// main thread, which Swift 6's runtime isolation check stops with a crash. Only the store work
// below hops to the MainActor, explicitly.
nonisolated enum AlertScheduler {
    static let taskIdentifier = "com.jeffquayle.MetarMate.alertcheck"

    // Register the launch handler. Must be called once at launch BEFORE launch completes
    // (from App.init), so the system can hand back a task it scheduled while the app was dead.
    // Deliberately takes NO container: holding the app-lifetime container open across a
    // background-launch suspension is what triggers RunningBoard 0xdead10cc on the App Group
    // store. The handler builds its own short-lived container when the task actually fires.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: refreshTask)
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

    private static func handle(task: BGAppRefreshTask) {
        // Reschedule the next cycle first, so a single run always sets up the next one even if
        // it's later cancelled by expiration.
        schedule()

        let work = Task { @MainActor in
            // Alerts are Pro (D#20). A lapsed or refunded user's watches stop here, with nothing
            // deleted. Entitlements are awaited first, so a payer's checks never stop on a cold launch.
            guard ProGate.allows(.alerts, isPro: await StoreManager.shared.isProWhenLoaded()) else {
                print("[AlertScheduler] skipped: alerts need MetarMate Pro")
                return
            }
            // Build a dedicated, short-lived container for THIS run. Scoping it to this closure
            // means its SQLite connection — and the App Group store's WAL lock — is released the
            // moment the work finishes, BEFORE we report completion and iOS suspends the process.
            // A long-lived container held across suspension is what triggers RunningBoard
            // 0xdead10cc. runChecks saves internally, so nothing is lost when the container goes.
            // nil: the store won't open. Skip the run; never recover from the background (#23).
            guard let container = ModelStore.makeBackgroundContainer() else { return }
            await AlertPipeline.runChecks(in: container.mainContext)
            // container + its mainContext go out of scope here → connection closed, lock released.
        }
        // iOS gives a limited window; if it expires, cancel the in-flight work so the container
        // is still torn down promptly rather than held until the watchdog fires.
        task.expirationHandler = { work.cancel() }

        let completion = Completion(task: task)
        Task {
            // Awaiting work.value returns only after the @MainActor closure above has fully
            // returned and released its container, so the lock is gone before we complete.
            _ = await work.value
            completion.task.setTaskCompleted(success: !work.isCancelled)
        }
    }

    // BGTask isn't marked Sendable, but setTaskCompleted may be called from any thread.
    private struct Completion: @unchecked Sendable { let task: BGTask }
}
