# Handoff — A3: App Review blockers, Pro gating + paywall, background task

**Repo worktree:** `/Users/jquayle/code/xcode/MetarMate-a3` (JAQ-Studio-Mac)
**Branch:** `fix/a3-release`, created off `feat/nearby-taf` (top of the release stack). Its first commit holds this handoff.
**Parallel session:** A2 (`fix/a2-missing-data`) runs at the same time in `/Users/jquayle/code/xcode/MetarMate`. See "Boundaries with A2".
**Read first:**
- `docs/DECISIONS_2026-10.md` (binding; D#18–21 for Pro)
- `docs/AUDIT_2026-10-12_full_codebase.md` (`#n` below)
- `docs/LAUNCH_CHECKLIST.md` sections 0, 4, 7

## Context

Launch model (Oct 21): **Pro is a $5.99 one-time non-consumable with Family Sharing, shipping at launch.**
- Free: favorites, search, crosswind calculator, go/no-go against the built-in starter profiles.
- Pro: unlimited custom minimums profiles, alerts, widgets (home and lock screen), Siri, layout customization, future Watch.
- ASOS Updates is a separate subscription that includes Pro. **ASOS is now at launch (Oct 23)**, but its architecture is still being decided; don't build ASOS here beyond keeping the entitlement model ready for "ASOS subscriber ⇒ Pro".

TestFlight testers currently get everything free via `FeatureFlags.favoritesRequirePro = false` and `WidgetDataManager.widgetsRequirePro = false`. **Beta testers must not lose features from this work.** Build the gating behind one switch that stays off in TestFlight builds until Jeff flips it.

Jeff is traveling: Phase 0 and diff summaries short and phone-readable. No device checks until he's home; prove things with simulator builds, unit tests, UI tests and the StoreKit configuration file.

The audit is from build 20; A1/Siri/nearby-TAF landed since (#22 privacy manifests and the ASOS product-ID gate are already done, `7fb7c29`, `49dd6d5`). **Re-verify every item against HEAD first.**

## Scope, in order

### Step 1 — App Review blockers
- **#21:** compile the test harness out unless a `TESTFLIGHT` Swift active-compilation condition is set. Set it only on the configuration used for TestFlight archives; propose how (separate build configuration or scheme) before doing it, since Jeff archives by hand. The App Store build must contain no harness code or entry chip. Add a UI test that the harness chip is absent in a Release build without the flag.
- **#23:** SwiftData `VersionedSchema` V1 that matches the current models exactly, plus a `SchemaMigrationPlan` with no stages yet. No `fatalError` on container failure: log it and recover. **Stop and ask before any recovery that moves or deletes the store** (it would lose favorites). Report whether A1 moved the store out of the App Group.
- **#28:** Info.plist: drop the unused `processing` background mode (confirm no `BGProcessingTask`), the Siri entitlement and `NSSiriUsageDescription` if App Intents don't need them (verify Siri still works in the simulator with the Shortcuts app), and request location accuracy that matches the coarse declaration.
- **#27:** launch-time reconcile of `AirportFavorite` against `airports.json`, keyed by ICAO (name, elevation, coordinates). Missing ICAO → keep the favorite, don't delete.

### Step 2 — Entitlements foundation (#24)
- StoreKit `Transaction.updates` listener started in `App.init`, not lazily.
- One entitlement source of truth (e.g. `Entitlements.isPro`), true for the Pro non-consumable **or** an active ASOS subscription, with a "loaded" state.
- Siri waits for entitlements to load before reading Pro (paying users must never hear "Pro required").
- Refund/revocation turns Pro off via `currentEntitlements`.
- Family Sharing: purchases shared from a family member count.
- Price always comes from StoreKit (`displayPrice`), never hard-coded.
- Add/extend the `.storekit` configuration file with the $5.99 Pro product so all of this is testable in the simulator.

### Step 3 — Gating, behind one switch
- One switch, e.g. `FeatureFlags.proGatingEnabled`, **false** for TestFlight until Jeff flips it. Retire `favoritesRequirePro`; fold `widgetsRequirePro` into the switch. Propose the switch design in Phase 0.
- **Free (remove any gate):** favorites (including the detail-view star), search, crosswind calculator, verdicts against built-in starter profiles.
- **Pro:**
  - Widgets, home and lock screen (lock-screen families were never gated, #24). Gated widget shows a clear "MetarMate Pro" state, not stale data.
  - Custom minimums profiles: creating, cloning or editing a non-built-in profile. Free users can select starters only. A lapsed user keeps their profiles stored but can't use them for verdicts until Pro returns (propose wording).
  - Alerts: creating an airport watch. Existing watches of a lapsed/refunded user stop, with a clear message; nothing is deleted.
  - Siri: free users get a short spoken answer that Siri is a Pro feature, with no weather data.
  - Layout customization.
- Unit tests for each gate in both switch states.

### Step 4 — Paywall screen
- Lists what Pro adds (from the D#19–20 list), price from StoreKit, Buy, **Restore Purchases**, Family Sharing note.
- Reached from every gated entry point. Propose the layout before building; keep the color axis rules (no green outside category/verdict).
- Check the copy for App Review 3.1.1 (restore present, no external purchase links).

### Step 5 — Beta testers and offer codes (D#20)
- Confirm in Apple's current documentation whether App Store offer codes work for a **non-consumable** IAP. Report what you find with the link. If they don't, propose the alternative (e.g. keep the switch off for TestFlight builds only) before building anything.

### Step 6 — Background task (#26)
- The expiry handler actually cancels the work; no SwiftData save after cancel.
- Network calls inside the task use short timeouts and run concurrently, not sequentially.
- The handler respects MainActor isolation (Swift 6).
- Watch `expiresAt` is enforced: expired watches don't run and are cleaned up.
- Don't change verdict logic in `AlertPipeline` (A2 owns that).

## Boundaries with A2 (parallel session)
- A2 owns parsers, models, `GoNoGoEvaluator`, trends, Pilot Notes, detail-view display logic, and the verdict path in `AlertPipeline`.
- A3 owns StoreKit, entitlements, gating, paywall, Info.plist, project settings, SwiftData schema, test-harness flags, `AlertScheduler` and background-task mechanics.
- Keep edits to shared files (`WeatherDetailView.swift`, `AlertPipeline.swift`) small and local; name them in the commit message.

## Out of scope
A2 items, ASOS/Synoptic implementation, App Store Connect setup (Jeff), P3 polish, Android.

## Rules
- **Planning first.** Phase 0 is read-only: status of each item at HEAD (file:line), the switch design, the TESTFLIGHT-flag approach and the offer-code finding. Wait for Jeff's go-ahead.
- **Build-verify before every commit:** `xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -8` ending in BUILD SUCCEEDED for app and widget, plus tests with `-parallel-testing-enabled NO`.
- **Don't bump the build number** in this pass; Jeff bumps it when he archives.
- **Diffs inline,** uncollapsed, before each commit. One commit per logical unit, specific paths only. Never stage `tools/madis/` or `MetarMate_Project_State.md`. Report hashes. **Ask before pushing.**
- **Flag scope changes before making them;** if D#18–21 don't cover a Pro question, stop and ask.
- **Commands for Jeff:** single line, `&&`/`;` chained, no `#` characters.
- **Keep `docs/LAUNCH_CHECKLIST.md` sections 4 and 7 current** in the same commit as each item, with the hash.
- **At the end:** a device-test list for when Jeff is home (sandbox purchase, restore, refund via StoreKit test, Family Sharing, each gate with the switch on and off, a Release build with no harness, background alert run).
