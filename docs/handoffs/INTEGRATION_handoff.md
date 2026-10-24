# Handoff — Integration: one launch build from all branches

**Worktree:** `/Users/jquayle/code/xcode/MetarMate-integration` (JAQ-Studio-Mac)
**Branch:** `integration/launch`, created off `feat/verdict-surfaces` (b3cb6f5, which already contains A2 up to 8db78cd). Its first commit holds this handoff.
**Session name:** blue. **Report file:** see Rules.

## Goal
One branch that builds, passes the full suite, and is archived tonight as **build 23** for Jeff's device checks. Merge with merge commits (no rebasing; every source branch is pushed and must stay as is).

## Order
1. `git merge fix/a2-missing-data`: one commit (`ac6b3b8`, the build-23 bump on 4 configurations). Expect a trivial result.
2. `git merge fix/a3-release`: 15 commits. A dry run shows three textual conflicts: `MetarMate/App/MetarMateApp.swift`, `MetarMate/Services/AirportService.swift`, `docs/LAUNCH_CHECKLIST.md`. Several files auto-merge but need a behavior check (below).
3. **Later, not now:** `fix/fetch-state-classification` is still being worked on in another session (`/Users/jquayle/code/xcode/MetarMate-fetchstate`). It isn't pushed yet. Don't touch that folder or branch. Jeff will tell you when to merge it; expect overlaps in `WeatherViewModel`, `WeatherDetailView`, `AlertsView`, the widget and `MetarPilotNotes`.

## Wiring the branches never saw each other
These are behavior seams, not text conflicts. Each gets its own commit with a test:
- **Profile seam.** `VerdictProfile.current()` (verdict branch) must call A3's `ProfileAccess.usableProfile(active:isPro:starters:)` with the real entitlement, so a lapsed user's verdicts use the starter fallback, and the detail card shows A3's lapse notice naming the starter.
- **Profile menu on the detail card.** Choosing a custom profile goes through the Pro gate (A3's paywall when gated). Starters stay selectable for everyone.
- **Widgets.** When the widget is locked ("MetarMate Pro"), it shows no verdict and no weather. When unlocked, the verdict line from the verdict branch shows. Check every family.
- **Alerts.** A lapsed user's paused watches (A3) and the shared verdict wording (verdict branch) must both hold: paused rows say "Paused" and show no GO/NO-GO badge.
- **Elevation.** A3's one-time refetch writes feet; A2 makes new favorites save feet; the verdict branch reads a non-bundled stored 0 as "not reported". Confirm all three agree with one test that runs the reconcile, then builds an `Airport` from the favorite.
- **Build number.** After the merges, `CURRENT_PROJECT_VERSION = 23` in all **six** app/widget configurations (Debug, Release, TestFlight); test targets stay 1. The version line in Customize Layout shows "(23)".

## Also in this pass
- **Background task tests** that A3 couldn't add because `AlertPipeline` was A2's: expiry stops the work with no SwiftData save after cancel, and network calls use the short timeouts. Tests only; change code only if a test shows a real bug, and ask first.
- **Flaky suite:** the unnamed full-suite failures on A2 and A3 were most likely sessions sharing one simulator. Run the full suite **three times** on your own simulator. If all pass, tick the checklist lines about it on both branches' sections, with that explanation.
- **Checklist:** one coherent `docs/LAUNCH_CHECKLIST.md` with every branch's ticks and hashes. Where two branches logged the same item (favorites elevation hand-off, the suite-stop line), keep one line with the final state.

## Build and test setup (don't share with other sessions)
- Create a simulator once: `xcrun simctl create "iPhone 17 Integration" "iPhone 17"` (pick the runtime the other sessions use).
- Build/test with `-derivedDataPath ~/Library/Developer/Xcode/DerivedData-integration` and `-destination "platform=iOS Simulator,name=iPhone 17 Integration"`; tests with `-parallel-testing-enabled NO`.
- Verify both the `MetarMate` scheme (Release build) and the `MetarMate TestFlight` scheme build for a generic iOS device (`-destination generic/platform=iOS`, no signing needed: `CODE_SIGNING_ALLOWED=NO`).

## Rules
- **Planning first, kept short.** After step 1 and the dry run of step 2, report the conflict hunks and your resolution plan for each, plus the seam plan. Wait for Jeff's go-ahead. Mechanical resolutions (both sides add independent lines) need no question; anything that changes behavior does.
- **Diffs in your reply** before each commit (conflict resolutions shown as the final hunk). Build-verify before every commit, ending in BUILD SUCCEEDED.
- Specific paths when staging; never stage `tools/madis/` or `MetarMate_Project_State.md`. **Ask before pushing.**
- No `?? <number>` for weather data; color axis rules unchanged.
- Commands for Jeff: single line, `&&`/`;` chained, no `#` characters.
- **Reports:** whenever you finish a reply that reports results or asks questions, also write that full reply (with diffs) as markdown to `/Users/jquayle/code/xcode/claude-reports/integration.md` (overwrite) and append it under a timestamp heading to `/Users/jquayle/code/xcode/claude-reports/integration-log.md`. That folder is outside the repo; never commit it.
- **At the end:** one combined device-test list for build 23, merged from the A2, verdict and A3 lists (`claude-reports/a3-log.md`, `claude-reports/verdict-log.md`, A2's list in `docs/LAUNCH_CHECKLIST.md` section 3), grouped by screen so Jeff can work through it in one pass.
