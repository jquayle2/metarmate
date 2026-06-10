import Foundation

// MARK: - AlertScheduler
// Background-task plumbing for the weather-alert checks. Part A defines only the task
// identifier — the single source of truth used by Part C's BGTaskScheduler.register and
// BGAppRefreshTaskRequest schedule calls. It MUST stay byte-for-byte identical to the
// BGTaskSchedulerPermittedIdentifiers entry in Info.plist; any drift makes the task silently
// never run (the classic background-task bug). Keeping it as one constant means the two Swift
// call sites can't disagree — only the Info.plist literal is hand-typed, and it's verified
// against this value.
enum AlertScheduler {
    static let taskIdentifier = "com.jeffquayle.MetarMate.alertcheck"
}
