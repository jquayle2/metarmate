# Handoff — Siri hands-free (launch checklist section 4, Siri #25)

**Branch:** create `feat/siri-hands-free` from `fix/launch-hardening-a1` (current head). Do not merge; Jeff merges.
**Written:** Oct 22, 2026, after an on-device Siri test at Kingman (KIGM).
**Read first:** `docs/LAUNCH_CHECKLIST.md` (section 4, Siri), `docs/DECISIONS_2026-10.md` (D#4 staleness rule), `MetarMate/Intents/FlyingWeatherIntent.swift`, `MetarMate/Intents/AirportEntity.swift`, `MetarMate/Services/AirportService.swift`.

## Goal

A pilot can say one phrase and hear the weather with no tap at any point. Siri never shows a list or a "Which one?" choice in the normal paths.

## What the device test showed (Oct 22, iPhone, at Kingman AZ)

1. First attempt went to Apple Weather instead of MetarMate.
2. "Check flying weather with MetarMate" (no airport) asked "Which airport?" and showed a list: 06NV, 07NV, 0CL3, 0L7, 3L2, 48AZ, 74P. Private strips, not the nearest, not sorted by distance.
3. Answering "Kingman" gave "Which one?" with KIGM Kingman and 9K8 Kingman/Clyde Cessna Field (Kingman, **Kansas**, no METAR). One attempt ended in "I couldn't find anything about that."
4. After tapping KIGM the card read "Sky clear · Vis 10+ sm · Wind 3kt". The METAR was `KIGM 221551Z AUTO VRB03KT 10SM FEW055 SCT100 19/13 A2996`. "Sky clear" is wrong with FEW/SCT layers.

## Causes (confirmed in code)

- `FlyingWeatherIntent.perform()`: when `airport` is nil it calls `$airport.requestValue("Which airport?")` and only uses location if that throws (cancel/timeout). The prompt is the default path.
- `AirportEntityQuery.suggestedEntities()` returns every `WidgetDataManager.loadAll()` snapshot in storage order. That cache holds any airport ever viewed, including non-METAR strips from Nearest.
- `AirportEntityQuery.entities(matching:)` returns `AirportService.search(query:limit: 10)` unfiltered: non-METAR fields included, no distance ranking, so a name like "Kingman" is ambiguous.
- `buildSummaryLine` uses "Sky clear" whenever `ceilingFeet == nil`.
- Every App Shortcut phrase contains "weather", which Siri can route to Apple Weather.

## Changes

1. **No airport named → nearest METAR station, no prompt.** Remove the `requestValue` default path. Use `IntentLocationHelper.currentLocation()` and `AirportService.nearest(to:count: 25)`, first with `hasMetar`. Only when location is denied or times out: say so in the dialog and suggest naming an airport ("Say: check flying weather at K-V-G-T with MetarMate"). Do not show a list.
2. **Suggested entities:** favorites first (in the user's order), then the nearest METAR stations by distance when location is available. METAR stations only. Cap at about 8. No raw snapshot dump.
3. **Name/ident matching (`entities(matching:)`):** METAR stations only. Rank: exact ICAO/IATA/LID match, then favorites, then distance from the current location (if available), then the existing search relevance. When there is an exact ident match, or only one METAR station matches, return just that one so Siri doesn't disambiguate. Keep the spoken-code O/0 handling (`airportForSpokenCode`).
4. **3-character LIDs** (CMA, 36K) resolve (existing open checklist item; use `noaaCandidate` if that helper exists, otherwise the existing identifier lookup with a K-prefix try).
5. **Report age (D#4):** Siri speaks the report age on every answer ("Kingman, 16 minutes ago: VFR…"). 65–75 min: says the report is late. Over 75 min (76+ whole minutes): says there is no current report, gives the age, and gives no category, conditions or verdict. Card shows the same. Use the same age/threshold helpers the widget uses (A1) so the boundaries match.
6. **Card and dialog wording:** "No ceiling" instead of "Sky clear" when there is no BKN/OVC/VV layer. Only say "Sky clear" when the METAR actually reports CLR/SKC with no layers. Spoken "Ceiling unlimited" can stay.
7. **Phrases:** add phrases led by the app name and phrases that avoid the bare word "weather", e.g. "\(.applicationName) nearest METAR", "Ask \(.applicationName) for the METAR", "\(.applicationName), how's the flying", "Get the METAR with \(.applicationName)". Keep the existing ones. Keep the airport-parameter phrases and call `MetarMateShortcuts.updateAppShortcutParameters()` at launch and whenever favorites change, so "…at KVGT…" matches the favorites.

## Out of scope

- Pro gating of Siri (#24, separate item). Leave the current `widgetsRequirePro` check as is.
- Nearby-TAF wording in Siri (section 4b).
- Any change to METAR/TAF parsing or verdict logic.

## Acceptance

- Builds: `xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -8`
- Unit tests (run with `-parallel-testing-enabled NO`): suggestion list is METAR-only and distance-sorted; "Kingman" with a location near KIGM returns only KIGM; exact ident returns one result; summary line says "No ceiling" for FEW/SCT and "Sky clear" only for CLR/SKC; age wording at 64, 65, 75 and 76 minutes.
- Commit per logical unit with specific file paths, clear messages. Show Jeff the diffs before each commit.
- Update `docs/LAUNCH_CHECKLIST.md` (section 4, Siri) in the same commits: mark items code-done with the commit hash; leave the device-check item for Jeff unchecked.
- Push the branch when done.

## Device check for Jeff (after install)

Hands-free, no touch:
1. "Check flying weather with MetarMate" → nearest METAR station spoken with its age.
2. "Check flying weather at KVGT with MetarMate" (a favorite).
3. "MetarMate nearest METAR" (new phrase) → does not open Apple Weather.
4. Location turned off for MetarMate → spoken guidance, no list.
