# Handoff — Go/no-go verdict on the detail screen and widgets

**Repo:** `/Users/jquayle/code/xcode/MetarMate` (JAQ-Studio-Mac)
**Branch:** `feat/verdict-surfaces`, created off `fix/a2-missing-data` (8db78cd). It needs A2's pass / fail / not-evaluated evaluator. Its first commit holds this handoff.
**Parallel session:** A3 is still running in `/Users/jquayle/code/xcode/MetarMate-a3` (`fix/a3-release`: entitlements, Pro gating, paywall, background task).
**Read first:**
- `docs/DECISIONS_2026-10.md` — D#1–4 (verdict rules), D#19–20 (free vs Pro)
- `docs/LAUNCH_CHECKLIST.md` sections 3 and 4
- `MetarMate/Models/GoNoGoEvaluator.swift`, `MetarMate/Models/MinimumsProfile.swift` (active-profile pointer), `MetarMate/Views/AlertsView.swift` (how verdicts render today)

## Why this pass exists

D#19 makes the go/no-go verdict on the detail screen, against the built-in starter profiles, part of the **free** app. D#20 puts the verdict on **widgets** (Pro). Neither exists: today verdicts appear only on the Alerts tab and in notifications. Found in A2/A3 Phase 0 (Oct 23).

Jeff is traveling: keep Phase 0 and diff summaries short and phone-readable. Prove things with unit tests and simulator builds/screenshots; device checks wait until he's home.

## Scope

### 1. One verdict model for every surface
- A single function that takes a METAR (+ runway data) and a profile and returns the display verdict: **GO**, **NO-GO**, **CHECK** (with the reason, D#2/D#3), **Late** (65–75 min, verdict still shown, D#4) or **No current METAR** (over 75 min, no verdict). Reuse A2's evaluator and the shared `ReportAge`; don't re-implement any rule.
- METAR only (D#1). 5-minute ASOS data never feeds it.
- Alerts, the detail screen and widgets all use it, so the three can never disagree. Move AlertsView onto it if it isn't already.

### 2. Which profile
- Use the existing active-profile pointer. Expose one seam, e.g. `VerdictProfile.current()`, that returns the profile to judge against. **A3 owns the Pro rule** (a lapsed user's custom profile falls back to a starter); keep that decision in this one function so A3 can hook it at merge time. Don't add gating here.
- The verdict always names its profile: starters as "GO vs VFR day starter" (use the starter's actual name), custom profiles by their name.
- A way to switch profile from the detail screen (e.g. tapping the label). Propose it in Phase 0.

### 3. Detail screen (free)
- A verdict row/card near the top. Propose placement and the look in Phase 0 before building.
- Each failing or CHECK factor listed with its value and limit ("Crosswind 18 kt · limit 15").
- **Color axis:** green/red only for GO/NO-GO; CHECK, Late and No-current are neutral; no category colors on this element; no amber unless it's a wind/pressure value.
- If it becomes a layout section (`SectionID`), new sections must appear for users with saved layouts. Fix the P3 bug where an unknown `SectionID` wipes saved layout prefs in the same commit, since adding a section is what triggers it.

### 4. Widgets (Pro by D#20; the whole widget is already Pro, so no extra gate here)
- The widget extension doesn't use SwiftData. The app writes the active profile's minimums (and its label) into the App Group widget snapshot; the widget evaluates with the same shared function. Propose the snapshot fields.
- Verdict on the families where it fits; propose which (likely home small/medium and lock-screen rectangular; circular and inline probably not).
- Timeline: the verdict disappears at obs+75 via the future entries A1 already schedules; at 65–75 it shows Late.
- The widget can't open SwiftData, so a profile changed in the app must refresh the snapshot.

### 5. Tests
Unit tests for the shared function across GO / NO-GO / CHECK (missing vis, VRB over limit, no runway data with strong wind) / Late / No-current, plus the widget snapshot round-trip and the layout-prefs fix. Simulator screenshots of the detail row and each widget family for Jeff.

## Out of scope
Pro gating, paywall, entitlements (A3); Siri speaking a verdict (ask in Phase 0 whether it already does); ASOS; Android.

## Rules
- **Planning first.** Phase 0 is read-only: what exists, placement and look, profile switching, snapshot fields, widget families, and questions. Wait for Jeff's go-ahead.
- **Diffs in your reply** before each commit (or a `git show --stat` plus the key hunks if long). Jeff reads on his phone.
- **Build-verify before every commit:** `xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -8` ending in BUILD SUCCEEDED, plus tests with `-parallel-testing-enabled NO`.
- One commit per logical unit, specific paths only; never stage `tools/madis/` or `MetarMate_Project_State.md`. Report hashes. **Ask before pushing.**
- **No `?? <number>`** for weather data. Unknown is never shown as good.
- Flag scope changes before making them; if DECISIONS doesn't cover it, ask.
- Commands for Jeff: single line, `&&`/`;` chained, no `#` characters.
- Keep `docs/LAUNCH_CHECKLIST.md` current in the same commit as each item.
- At the end: a device-test list for when Jeff is home.
