# MetarMate — Product decisions, October 2026

Decided by Jeff on Oct 20, 2026. These are binding for implementation. Items marked **Mike: confirm** go to Mike as yes/no confirmations, not open questions. Audit numbers refer to the Oct 12, 2026 full-codebase audit.

## Go/no-go and verdicts

1. **Verdict source is the METAR only.** 5-minute ASOS/OMO data never sets or changes a go/no-go verdict, flight category or gust. (Removes the "5-min ob with no gust flips NO-GO to GO" path, `AlertPipeline.swift:150`.)
2. **Missing fields (#4, #6, #8, #10, #12, #15).** A missing METAR field is labeled "not reported" wherever it would appear. A minimum that can't be checked is never treated as passing:
   - The verdict becomes a neutral **CHECK** naming the missing field (e.g. "CHECK: visibility not reported").
   - A transition into CHECK never sends "Back within your minimums."
   - Missing never becomes a number (no 0 °C, 29.92, 0 kt, 000°, 0 ft, 10 SM, 99,000 ft, or `Date()` for obs time).
3. **VRB wind (#5).** Labeled "Variable". Crosswind is evaluated worst case, as a direct crosswind at the gust if reported, otherwise the sustained speed:
   - Worst case within the crosswind minimum: evaluated normally, labeled "VRB, assuming full crosswind".
   - Worst case exceeds the minimum: **CHECK**, "Variable wind: crosswind can't be confirmed". Not NO-GO.
4. **Stale METARs (#7, #17).** Age comes from the observation time, never fetch time, and is always visible.
   - Under 65 min: normal.
   - 65 to 75 min: **Late** warning, e.g. "METAR late: 68 min old". The verdict is still shown.
   - Over 75 min: **No current METAR**, with the age shown ("Last report 2 h 10 min ago"). No go/no-go verdict at all. Widgets and lock-screen widgets follow the same rule.

## 5-minute data (ASOS Updates)

5. **Warn, never reassure.** 5-minute values worse than the latest METAR (lower ceiling, lower vis, more wind) may be shown as a warning. Better values never change category, verdict or gust.
6. **Displayed gust** = the higher of the current METAR's gust and any 5-minute gust in the last 10 minutes, labeled by source. A 5-minute ob with no gust means "gust not reported", never "no gust".
7. 5-minute data is labeled supplemental, not official. ASOS Updates stays off until the data source is chosen (see Data source below). **Mike: confirm label wording.**

## Pilot Notes

8. **Gust approach-speed additive (#20).** Half the gust factor (gust minus sustained), rounded up, from the METAR gust. Source: FAA Airplane Flying Handbook, FAA-H-8083-3C, Ch. 9 (turbulent air approach). One shared function for Pilot Notes and the crosswind calculator. Wording: "Gusty: consider +5 kt (½ gust factor, or per your POH)". The current "half the gust" formula is wrong (15G25 gives +12 instead of +5). **Mike: confirm.**
9. **Crosswind note floor.** Keep 5 kt. Below that, no Pilot Note; the runway display still shows the component.
10. **CFII item 6.** Missing-field notes are symmetric. Any missing safety-relevant field gets the same neutral "not reported" note.
11. **F17.** Observation-history lines show hazardous present weather: at minimum TS, SQ, FC (including +FC), GR, and freezing precipitation.
12. **PROB thunderstorms in the TAF headline.** Thunderstorms reach the headline at any probability, with probability and time ("PROB30 TSRA after 2 PM"). Non-convective PROB groups stay in the detail.

## Nearby-TAF fallback (Oct 16 addendum)

13. When the field has no TAF, use the nearest TAF within **50 nm**.
14. **Label it everywhere:** "TAF from KLAS · 9 nm SW", in the detail view, widget and Siri.
15. **Forecast accuracy and the Forecast Deviation Strip** compare the TAF station's forecast against **that station's own METARs**, labeled (e.g. "KLAS forecast vs KLAS actual"). They are never computed against this field's METAR.
16. **"Right now" row:** this field's current METAR beside the TAF station's. Warn-never-reassure applies: if this field is worse, show "Conditions here are worse than at the TAF site"; if it's better, say nothing.
17. **Cautions:**
    - Elevation difference of 1,000 ft or more: "TAF site is N ft lower/higher".
    - Distance over 25 nm: the distance is included in the caution.
    - Mockup reviewed and approved Oct 20, 2026.

## Business model (launch)

18. Free app at launch, with no IAP in the first submission. Small Business Program: enrolled.
19. **Free forever:**
    - METAR/TAF decode, flight category, nearest, search, favorites.
    - Trend card, Forecast Deviation Strip, Pilot Notes (including the crosswind warning), density altitude, advisory weather.
    - Safety-relevant information is never paywalled.
20. **Pro, one-time (~$2.99):**
    - Decided: crosswind calculator, widgets (including lock screen).
    - Proposed, Jeff to confirm: Siri/Shortcuts, personal minimums and go/no-go alerts, layout customization, future Watch.
    - TestFlight testers get Pro via offer codes.
21. **ASOS Updates:** a subscription added after launch. It includes Pro. It uses a StoreKit introductory offer; the old 60-day first-launch free period is removed.
22. **XW Calc** becomes a free funnel into MetarMate. Its development is frozen.

## Data source for ASOS Updates

23. The research spike (branch `spike/madis-omo`, `docs/research/MADIS_ASOS_findings.md`) recommends MADIS hfmetar behind a small proxy: a scheduled ingest job publishing per-station JSON to a CDN.
24. **Before building:**
    - MADIS support confirms licensing for use in a paid app.
    - Phase 2 (with a MADIS account) reruns the freshness and gust tests.
    - Optionally, a Synoptic eval token to compare latency.
    - Synoptic starter plan: $100/month, held in reserve.

## Mike: confirmation list

- [ ] #2 CHECK for unevaluated minimums, with no "back within minimums" alert
- [ ] #3 VRB worst-case crosswind; CHECK when it decides the outcome
- [ ] #4 Staleness: late at 65 min, no verdict over 75 min
- [ ] #5–7 Warn-never-reassure, the displayed-gust rule, the supplemental label wording
- [ ] #8 ½ gust factor, with the stated wording
- [ ] #9–12 5 kt crosswind floor, symmetric missing notes, F17 hazards in history, PROB TSRA in the headline
- [ ] #13–17 Nearby-TAF cap, labels and cautions
