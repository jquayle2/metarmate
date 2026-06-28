# MetarMate — Revert XW Calc Toggle; Keep Conversion ONLY in Pilot Notes

## Decision (Jeff, final)
Remove the MAG/TRUE wind-source toggle and ALL true→magnetic conversion from the XW calculator (both the manual XWind tab AND the sheet launched from a METAR). The calculator goes back to dumb-and-honest: designator×10 vs the wind as-typed/as-passed, NO conversion, NO GPS, NO toggle.

KEEP the true→magnetic conversion ONLY in MetarMate's Pilot Notes / auto-computed runway crosswind (RunwayService.bestRunway path), so those numbers match ForeFlight. That part is correct and verified (KVGT 19/9, KSDL 0/5) — do NOT touch it.

This supersedes XW_SOURCE_TOGGLE_BRIEF.md entirely.

## Task 1 — fully remove the toggle + GPS feature
- Delete WindFrameToggle.swift (the WindFrame enum, WindFrameConfig, the segmented MAG/TRUE control, provenance indicator, legend).
- CrosswindKeypadView.swift: remove the windFrame binding/config, the toggle rendering, and the true→magnetic conversion-on-commit. Wind entered is used AS-IS. Revert to plain designator×10 crosswind/headwind/side math on the typed values.
- CrosswindTabView.swift (manual tab): remove all toggle/GPS code. Pure manual designator×10. No CoreLocation usage.
- RunwayCrosswindSheet.swift (METAR-launched sheet): remove the pre-set-to-TRUE behavior, the "TRUE (METAR) → MAG" indicator, and the conversion. The sheet now seeds from the METAR wind AS-IS (raw value) and computes designator×10 — same as the manual tab. (Accept that this sheet's crosswind will differ from Pilot Notes on the same airport; that's intended — calculator vs decision-support.)
- Info.plist: remove the NSLocationWhenInUseUsageDescription text that was added/broadened for magnetic-variation, IF nothing else in the app uses location. CHECK FIRST: if LocationService / CoreLocation is used elsewhere (e.g. Nearest airports GPS), DO NOT remove the permission string — just revert any wording that referenced magnetic variation back to its original. Nearest almost certainly uses location, so likely: keep the permission, restore original usage string.
- Remove the double-convert guard and any TRUE-mode plumbing that's now dead.

## Task 2 — DO NOT TOUCH (keep working)
- RunwayService.swift bestRunway() / crosswinds() magnetic-frame conversion — KEEP. Pilot Notes and alerts rely on it and it matches ForeFlight.
- MagneticDeclination.swift (WMM) — KEEP. Still used by RunwayService for the Pilot Notes conversion. Do not delete even though the toggle no longer uses it.
- WeatherDetailView Pilot Notes crosswind lines — KEEP as-is (converted, correct).
- Decoded METAR block — unchanged (raw true wind shown).

## Net behavior after revert
- Pilot Notes / auto crosswind: converted to magnetic, matches ForeFlight. (unchanged)
- XWind manual tab: type runway + wind, designator×10, no conversion, no toggle. (as it originally was)
- XW sheet from a METAR: seeds raw METAR wind, designator×10, no toggle. (simpler; will differ from Pilot Notes on same airport — intended)

## Verify
- XWind tab: RWY 25, wind 134, 21G30 → designator math on 134 as-typed, no toggle visible, no GPS prompt. (matches the old behavior)
- Open XW sheet from KSDL detail: shows raw METAR wind, designator×10, no toggle, no "TRUE→MAG" text.
- KVGT Pilot Notes STILL shows RWY 25, 19 XW / 9 HW (conversion intact). KSDL Pilot Notes STILL shows RWY 21, 0/5.
- No location permission prompt triggered by the XWind tab anymore.
- Confirm Nearest still works (location permission not broken).

## Build / commit
- xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5
- Single commit: "Revert XW calculator true/mag toggle and GPS; keep conversion in Pilot Notes only".
- No # in terminal commands; single-line.

## Files
- DELETE: MetarMate/Views/WindFrameToggle.swift
- EDIT: CrosswindKeypadView.swift, CrosswindTabView.swift, RunwayCrosswindSheet.swift
- CHECK/MAYBE-EDIT: project.pbxproj or Info.plist (location usage string — only revert wording, keep permission if Nearest uses it)
- DO NOT TOUCH: RunwayService.swift, MagneticDeclination.swift, WeatherDetailView.swift Pilot Notes


---

## Additional removal (same revert): remove the "open XW calc prefilled from METAR" affordance
Beyond reverting the conversion, also REMOVE the entry points that open the crosswind sheet pre-filled from a METAR:
- The "XW ›" tappable affordance on the Decoded METAR wind row in WeatherDetailView (the one that opened RunwayCrosswindSheet seeded from the current METAR wind).
- Any other tap-to-open-crosswind-sheet-from-a-wind-display that pre-fills from the METAR.
- The RunwayCrosswindSheet itself can be removed entirely if nothing else presents it after these affordances are gone. If it's cleaner to leave the type but unreferenced, that's fine, but remove the presentation/buttons and the prefill wiring.

Rationale: with the calculator no longer converting, a METAR-launched sheet would show crosswind numbers that differ from Pilot Notes on the same airport. Removing the affordance keeps ONE source of auto crosswind from a METAR — Pilot Notes (converted, matches ForeFlight). 

KEEP: the standalone XWind TAB in the bottom tab bar (manual entry, designator×10, no prefill). That is the deliberate manual calculator and stays.

KEEP: Pilot Notes converted crosswind (unchanged).

Note for later: when ASOS 5-minute data is re-enabled, ASOS-derived crosswind will be surfaced in Pilot Notes (same converted path), not via the calculator. No action now — just the intended direction.

## Updated verify
- No "XW ›" button on the Decoded METAR wind row; tapping the wind does nothing (or whatever the default non-interactive behavior is).
- XWind tab still reachable from the bottom bar, manual, designator×10, no prefill, no toggle, no GPS.
- Pilot Notes crosswind unchanged (KVGT 19/9, KSDL 0/5).


---

## Additional task (same pass): hide the ASOS "Subscribe" teaser — not currently purchasable
The "ASOS Updates — Subscribe for 5-minute weather updates between METARs" card is showing again. ASOS is NOT a purchasable option right now (subscription products dropped, data layer off until funded later). A "Subscribe" card that leads to a dead/unavailable purchase is confusing and an App Store rejection risk. Hide it until ASOS is genuinely available.

Current gate (WeatherDetailView.swift, ~line 44-46):
```
if store.isAsosUser, vm.hasASOSData, let obs = vm.synopticLatest {
    decodedASOSSection(obs)
} else if !store.isAsosUser, vm.metar != nil {
    asosProTeaser            // <-- this card. shows for ALL non-ASOS users = everyone now.
}
```

### Required
- Add a single feature flag, e.g. `static let asosAvailable = false` in a sensible config spot (FeatureFlags-style; check if a flags file already exists, otherwise a simple constant). Default OFF.
- Gate the `asosProTeaser` so it ONLY shows when `asosAvailable` is true. With the flag off, the teaser never renders; the view falls through to the METAR sections.
- Audit for OTHER ASOS purchase/subscribe entry points and gate them on the same flag: any "ASOS Updates" upsell in settings, the Pro upgrade screen's ASOS subscription rows, Siri/Shortcuts mentions, etc. The goal: with `asosAvailable = false`, a user sees NO path to buy/subscribe to ASOS anywhere.
- Do NOT rip out the ASOS code itself (decodedASOSSection, SynopticService, StoreManager ASOS logic) — keep it intact behind the flag so re-enabling later is flipping `asosAvailable = true`. This mirrors the "one switch brings it back" intent. Same place ASOS-derived crosswind will surface in Pilot Notes when re-enabled.
- For any EXISTING ASOS subscribers (unlikely given products dropped, but defensively): `store.isAsosUser && vm.hasASOSData` path can still render real ASOS data if present — gating only the SUBSCRIBE TEASER, not the data display, is fine. But since products are gone there should be no active subscribers. Keep the data path intact behind the flag too if simpler.

### Verify
- KVGT detail (non-ASOS user): NO "ASOS Updates / Subscribe" card. View goes header → decoded METAR → Pilot Notes with no teaser.
- No ASOS subscribe option anywhere in settings or Pro upgrade screen.
- Flipping `asosAvailable = true` brings the teaser back (confirm the flag is the only gate).
