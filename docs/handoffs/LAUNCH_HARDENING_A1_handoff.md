# Handoff — Launch hardening A1: the three P0s

**Repo:** `/Users/jquayle/code/xcode/MetarMate`
**Branch:** `fix/launch-hardening-a1`, already created off `origin/feat/trend-time-spine` (9c48d7b). Its first commit holds `docs/DECISIONS_2026-10.md` and this handoff.
**Read first:**
- `docs/DECISIONS_2026-10.md` (binding)
- `docs/WIND_REFERENCE_FRAMES.md`
- `docs/AUDIT_metar_taf_findings.md`

## Context

MetarMate is heading to a free public App Store launch. The Oct 12, 2026 full-codebase audit was done at build 20 (5ad1b4b) and found three P0s. The spine has moved on since then:
- the 0xdead10cc crash-fix branch is now merged,
- store recovery changed (438c702),
- the widget switched to a static observation time (9c48d7b).

So **re-verify every item against HEAD before changing anything.** Some may already be fixed.

## Scope

### P0-1: Widget never refreshes; refresh button does nothing

Audit findings, all to be re-checked:
- **Reload loop.** `ConfigurableProvider.timeline()` / `snapshot()` call `WidgetDataManager.save(snapshot:)`, which calls `WidgetCenter.shared.reloadAllTimelines()`. Every widget run reloads all widget kinds, which burns the WidgetKit budget.
- **Refresh button.** `RefreshWidgetIntent.perform()` calls `reloadAllTimelines()` from the extension. That is a budgeted no-op.
- **Network.** The widget fetch uses `URLSession.shared` with the 60 s default timeout.
- **Trend line.** On widget-only refreshes, trend/TAF lines come from the stale app cache.

Fixes:
1. `save(snapshot:reload: Bool = true)`, passing `reload: false` from the provider. `save(snapshots:)` reloads once per batch.
2. `RefreshWidgetIntent.perform()` just returns `.result()`. The system reloads the tapped widget.
3. Widget fetch: `URLRequest` with `.reloadIgnoringLocalCacheData` and a ~10 s timeout.
4. **Staleness per DECISIONS #4, all widget families including lock screen (#17).** Age is based on observation time. Since the widget can't flip state without a reload, the timeline provider must emit future entries:
   - one at obs+65 min (Late state),
   - one at obs+75 min ("No current METAR", no verdict, greyed).

   Keep the static observation time from 9c48d7b, and add the late/stale states. `isStale` must use observation time, not fetch time. Propose the visual for each family before building it.
5. Trend/TAF lines on a widget-only refresh: label them "as of <time>", or drop them. Propose which.

### P0-2: 0xdead10cc launch-crash exposure

Audit findings: `sharedModelContainer` is built eagerly in `App.init` on every launch, including background alert and Siri launches, in the App Group container. `AlertPipeline` saves right before `setTaskCompleted`, and the expiry path keeps saving after cancel.

What to check and fix:
1. Report what the merged crash-fix branch (34db3e3, c16065f) already covers.
2. Close what remains:
   - the container is created lazily (e.g. `enum AppStore { static let container }`),
   - `AlertScheduler.register()` doesn't touch the container until there's work,
   - no save when `Task.isCancelled`,
   - the expiry handler actually stops the work.
3. **Stop and ask before** moving the store out of the App Group into Application Support. The widget doesn't use SwiftData, so the move is the robust fix, but it's a one-time store migration and needs Jeff's go-ahead and a test plan.

### P0-3: Synoptic/ASOS reachable despite the flag being off

Audit findings: `StoreManager.isAsosUser = isAsosSubscriber || isAsosInFreePeriod` (60 days from first launch), and none of its call sites check `FeatureFlags.asosAvailable`. Call sites include `WeatherViewModel.swift:92`, `AlertPipeline.swift:116` and `WeatherDetailView.swift:41`. The token is hard-coded in `SynopticService.swift`, and Jeff's Synoptic account has expired.

Fixes:
1. `isAsosUser = FeatureFlags.asosAvailable && isAsosSubscriber`. Remove the 60-day first-launch free period entirely; DECISIONS #21 replaces it with a StoreKit intro offer later.
2. Prove no Synoptic request can happen while the flag is off. Grep every `SynopticService` entry point and list each one with its gate.
3. **DECISIONS #1:** `AlertPipeline` never uses 5-minute data for a verdict, whatever the flag says. Remove that path. Keep only the change needed to make alerts METAR-only. The CHECK/missing-field verdict logic is A2, not this pass.
4. Propose, without doing it yet: removing the expired hard-coded token from source, so `SynopticService` reports "not configured" until the future proxy exists.

## Out of scope (later passes, don't start)

- **A2:** parser "unknown never a value" fixes, and go/no-go CHECK / VRB / staleness verdict logic (#4–16), per DECISIONS.
- **A3:** App Review blockers (#21 test harness, #22 privacy manifests, #23 VersionedSchema), Pro gating (#24), Siri (#25), background task (#26).
- Any ASOS/MADIS data work. No Android.

## Rules

- **Planning first.** Phase 0 is a read-only report: the status of each P0 sub-item at HEAD (already fixed / partly / open), with file and line, and your plan. Wait for Jeff's go-ahead.
- **Build-verify before every commit.** Show `xcodebuild` ending in BUILD SUCCEEDED for the app and the widget extension.
- **Diffs inline,** uncollapsed, before each commit. Commit per logical unit, staging specific paths only. `tools/madis/` and `MetarMate_Project_State.md` are untracked here; never stage them. Report hashes. **Ask before pushing.**
- **No `?? <number>` anywhere.** Unknown values skip or omit; they never get a benign default.
- **Flag scope changes before making them.** A code fix must not double as a product ruling. If something isn't covered by DECISIONS, stop and ask.
- **Commands for Jeff:** single line, `&&`/`;` chained, no `#` characters.
- **At the end:** a device test checklist for Jeff, covering:
  - widget refresh over a few hours without opening the app,
  - the refresh button,
  - the late and stale states (simulated via a debug date override if one exists; otherwise propose one),
  - a background alert run,
  - a cold launch after the app has been suspended.
