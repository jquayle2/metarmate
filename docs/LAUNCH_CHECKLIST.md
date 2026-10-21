# MetarMate — Launch Checklist

**Single source of truth for everything between now and App Store release.**
Started Oct 21, 2026. Release line: `feat/trend-time-spine` (build 1.2 (21)).

How this list is maintained:
- Claude (chat) or Claude Code updates it at the end of any session that changes status, in the same commit as the work where possible.
- Check an item only when it's verified (built, tested, or confirmed by the named person). Not just "code written".
- Refs: `#n` = `claude/AUDIT_2026-10-12_full_codebase.md`, `D#n` = `docs/DECISIONS_2026-10.md`.
- Owner tags: **[Jeff]**, **[Mike]**, **[Code]** (Claude Code), **[Claude]** (chat).

---

## 0. Decisions needed before scope is final [Jeff]

- [ ] **ASOS Updates at launch or after?** D#18 says no IAP in the first submission; the Synoptic paid plan may change that. If "at launch", section 6 moves onto the critical path.
- [ ] **Pro at launch or after?** D#18 (no IAP at launch) conflicts with D#20 (widgets and crosswind calculator are Pro). Pick one; it decides whether section 4's Pro gating items are launch blockers.
- [ ] **Pro scope:** confirm Siri/Shortcuts, personal minimums + go/no-go alerts, layout customization (D#20, proposed).
- [ ] **Nearby-TAF fallback (D#13–17): launch or 1.3?** Mockup approved Oct 20; not built.
- [ ] **Siri staleness rule:** apply late/no-current (65/75 min) to Siri answers? Yes/no, then into DECISIONS.
- [ ] **P3 triage:** which items in section 5 are launch-required.
- [ ] **Proxy hosting** for ASOS: Cloudflare Worker (proposed) or other.

## 1. Mike sign-off [Mike]

Send the confirmation list at the bottom of `docs/DECISIONS_2026-10.md` as one packet.
- [ ] Packet sent [Jeff]
- [ ] D#2 CHECK for unevaluated minimums, no "back within minimums" alert
- [ ] D#3 VRB worst-case crosswind; CHECK when it decides the outcome
- [ ] D#4 Staleness: late 65 min, no verdict over 75 min
- [ ] D#5–7 Warn-never-reassure, displayed-gust rule, supplemental label wording
- [ ] D#8 ½ gust factor, with the stated wording
- [ ] D#9–12 5 kt crosswind floor, symmetric missing notes, F17 hazards, PROB TSRA in headline
- [ ] D#13–17 Nearby-TAF cap, labels, cautions (only if in launch scope)

## 2. A1 — launch hardening P0s (`fix/launch-hardening-a1`)

Code done: 7 commits (`d28cbab`…`1fe5edc`), builds, 58/58 unit tests. Pushed, not merged.
- [x] Widget reload loop removed; refresh intent no longer calls `reloadAllTimelines()` (#1)
- [x] Widget fetch: no URL cache, 10 s timeout (#1)
- [x] Late (65 min) / no-current (75 min) states in every widget family, from observation time (#1, #17, D#4)
- [x] Trend/TAF/deviation reused only for the same observation (#1)
- [x] SwiftData store opened only from window content; open logged with app state (#2)
- [x] ASOS free period removed; hard-coded Synoptic token deleted (#3)
- [x] Alerts are METAR-only (D#1)
- [x] **Unconfigured widget fetches live** (falls back to the last-viewed ICAO). Found Oct 21: an unconfigured widget never fetched. `9fa71fa` [Code]
- [x] **`widget.diag` breadcrumb**: last 40 provider runs (time, kind, ICAO, configured/fallback, fetch outcome) in the App Group. `b8a732c` [Code]
- [ ] Device check: widget refreshes on its own for 3–4 h without opening the app (KVGT configured Oct 21, 9:45 AM) [Jeff]
- [ ] Device check: refresh button [Jeff]
- [ ] Device check: late / no-current states via the DEBUG age override, then set it back to Off [Jeff]
- [ ] Device check: background alert run (debugger attached) [Jeff]
- [ ] Device check: cold launch after suspension, no 0xdead10cc [Jeff]
- [ ] Merge A1 into `feat/trend-time-spine` [Jeff]

## 3. A2 — missing data never shown as a value; verdict logic [Code]

- [ ] #4 Go/no-go tri-state: unevaluated minimum → CHECK, never GO; no "back within minimums" alert (D#2)
- [ ] #5 VRB worst-case crosswind (D#3)
- [ ] #6 Unknown sky ≠ unlimited ceiling
- [ ] #7 Staleness gate on verdicts (D#4)
- [ ] #8 / F15 Missing temp/dewp/altim are optional, not 0 °C / 29.92 (density altitude, pressure trend, fog, app-written widget snapshot)
- [ ] #9 Visibility trend against "10+" (P6SM); `.unknown` not `.steady` when both axes unknown
- [ ] #10 Missing wind direction/speed not reported as 000° / 0 kt
- [ ] #11 Red-tier crosswind not hidden under "Red only" Pilot Notes
- [ ] #12 Missing cloud base not 0 ft
- [ ] #13 TAF: one "period covering time t" helper (overlays, expired periods/TAFs, BECMG, TafHeroBrief)
- [ ] #14 TAF category with one axis unknown; clouds into overlays
- [ ] #15 Missing `obsTime` not `Date()`
- [ ] #16 Unknown shown as good (green rail, "Clear", "Fcst on target", wind-only "Steady")
- [ ] #18 Category boundary drift (`cloudLayerColor`, Synoptic LIFR, ASOS/advisory category)
- [ ] #19 TAF Pilot Notes: strong steady winds and overlay gusts
- [ ] #20 Gust approach speed = ½ gust factor, one shared function (D#8)
- [ ] D#10 symmetric missing-field notes; D#11 F17 hazards in history; D#12 PROB TSRA in headline
- [ ] F16 present-weather chip off the category red; F18 "Clear" with only FEW/SCT
- [ ] Unit tests for the gaps listed in the audit (DensityAltitude, trends, TafVerification, `currentForecast`, BECMG, advisory category, parser missing-field cases)
- [ ] Merge A2 [Jeff]

## 4. A3 — App Review blockers, Pro gating, Siri [Code]

App Review blockers (required regardless of section 0):
- [ ] #21 Test harness compiled out with a `TESTFLIGHT` flag set only on TestFlight archives (2.2 rejection risk)
- [ ] #22 Privacy manifest: `NSPrivacyAccessedAPITypes` for UserDefaults (CA92.1, 1C8F.1); add `PrivacyInfo.xcprivacy` to the widget extension (ITMS-91053)
- [ ] #23 SwiftData `VersionedSchema` V1 + migration plan; no `fatalError` on container failure
- [ ] #28 Info.plist: drop unused `processing` background mode, Siri entitlement / `NSSiriUsageDescription`; location accuracy matches coarse declaration

Pro gating (blocker only if Pro ships at launch, section 0):
- [ ] #24 Siri waits for entitlements before reading `isProUser`
- [ ] #24 Lock-screen widgets gated
- [ ] #24 StoreKit listener started in `App.init`
- [ ] #24 Stop requesting ASOS product IDs until ASOS ships
- [ ] Flip `FeatureFlags.favoritesRequirePro` / `WidgetDataManager.widgetsRequirePro` per the final Pro scope
- [ ] TestFlight testers get Pro via offer codes (D#20)

Siri (#25):
- [ ] Use location instead of prompting "Which airport?"
- [ ] `nearest(count:1)` respects `hasMetar`
- [ ] 3-character LIDs (CMA, 36K) resolve via `noaaCandidate`
- [ ] Remove the `O→0` rewrite that corrupts O-prefixed ICAOs
- [ ] Siri staleness rule, if approved (section 0)

Background task (#26):
- [ ] Expiry handler stops the work; no save after cancel
- [ ] Synoptic calls: short timeouts, not sequential
- [ ] MainActor isolation of the handler
- [ ] Watch `expiresAt` enforced

Other:
- [ ] #27 Favorites reconcile with `airports.json` at launch
- [ ] Merge A3 [Jeff]

## 5. P3 polish — triage in section 0 first

- [ ] Green outside category/verdict (calm wind, steady wind, `ForecastStripColumn`, `TrendDirection.color`, accuracy colors, `spreadColor`, widget `trendColor`)
- [ ] Crosswind calculator: tiers unused, tailwind limit text, tailwind uses sustained only, gust carries over between sessions
- [ ] Trend arrow up for steady/unknown; VoiceOver "improving or stable" for unknown; LIFR folded into IFR on TAF ribbon; VV labelled "Broken"
- [ ] Accessibility: airport rows show category by color rail only, no text, no age
- [ ] Performance: `DateFormatter` in view bodies; `pilotNotes()` and density altitude computed twice per render
- [ ] Misc: search race, layout prefs wiped on unknown `SectionID`, Open-Meteo timeouts/cancellation, alert `force` vs METAR cache, `seedSimulated` empty trap, `M1/4SM`, ceiling `.first` vs `.min()`, two DA formulas, PROB defaults

## 6. ASOS Updates — Synoptic (launch-blocking only if section 0 says so)

Source decided Oct 21: Synoptic paid plan. New trial token (~7 days) incoming. MADIS stays as fallback (spike: `spike/madis-omo`).
- [ ] Synoptic confirms: display in a paid app via our own proxy with shared caching is licensed [Jeff]
- [ ] Synoptic confirms: rate limits on the paid plan; trial = same data/latency as paid [Jeff]
- [ ] Trial token received [Jeff]
- [ ] Validation rerun with the trial token: latency, gust capture, timeouts vs the same METARs (spike harness) [Code]
- [ ] Go/no-go on paying, based on the validation [Jeff]
- [ ] Proxy built: token server-side only, StoreKit JWS verification, ~5 min per-station cache, per-user quota [Code]
- [ ] Proxy deployed; deployment record kept (what's deployed, from which commit, how to redeploy) [Code]
- [ ] Rotate token after trial → paid switch; never in the app binary [Jeff]
- [ ] `SynopticService` talks to the proxy, not Synoptic [Code]
- [ ] Fix the 13 app sites flagged by the spike [Code]
- [ ] D#5–7 implemented (warn-never-reassure, displayed gust, supplemental label) [Code]
- [ ] ASOS Updates subscription products + introductory offer set up in App Store Connect [Jeff]
- [ ] Sandbox purchase → proxy → data works end to end [Jeff]
- [ ] `FeatureFlags.asosAvailable = true` [Code]
- [ ] Old Synoptic token rotated/revoked (exposed in earlier binaries) [Jeff]
- [ ] Paid plan active before the trial ends [Jeff]

## 7. App Store Connect and submission [Jeff]

- [ ] Version/build bumped (app + widget, Debug + Release)
- [ ] App name, subtitle, keywords, description
- [ ] Screenshots: 6.9" and 6.5" iPhone, 13" iPad (iPad is supported)
- [ ] App Privacy ("nutrition label") matches what the app collects (location, purchases)
- [ ] Privacy policy URL and support URL live on the marketing site
- [ ] Age rating questionnaire
- [ ] Export compliance (encryption) answered
- [ ] Data attribution where required (Open-Meteo CC BY 4.0; Synoptic per license)
- [ ] Aviation disclaimer in-app and in description (supplemental, not an official briefing)
- [ ] App Review notes: how to reach each feature; demo airport; IAP notes if any
- [ ] Final TestFlight round from the release branch; tester sign-off
- [ ] Release archive built from the merged release line; tag the commit

## 8. Repo and housekeeping [Jeff / Claude]

- [ ] Decide fate of `main` (060da26, far behind): fast-forward from the release line after launch
- [ ] `MetarMate_Project_State.md` updated, committed, re-uploaded to Project knowledge
- [ ] `tools/madis/` stays untracked on non-spike branches
- [ ] Marketing site updated for launch (metarmate-site)

---

## Log
- **Oct 21, 2026:** List created. Widget "not refreshing" root-caused to an unconfigured widget (no airport set → cache only); configured to KVGT, unconfigured-fetch fix added to section 2. Synoptic chosen as ASOS source.
