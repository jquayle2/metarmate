# MetarMate — Product decisions, October 2026

Decided by Jeff on Oct 20, 2026. These are binding for implementation. Oct 21: Jeff confirmed every item, including the ones previously marked for Mike; no Mike sign-off is required for launch. Audit numbers refer to the Oct 12, 2026 full-codebase audit.

## Go/no-go and verdicts

1. **Verdict source is the METAR only.** 5-minute ASOS data never sets or changes a go/no-go verdict, flight category or verdict gust; in particular it never turns a NO-GO into a GO. Revisit only by a new decision (reaffirmed Oct 21). (Removes the "5-min ob with no gust flips NO-GO to GO" path, `AlertPipeline.swift:150`.)
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
   - A SPECI counts as a METAR here: it resets the age.
   - **Siri** (Oct 21): always speaks the report's age ("As of 12 minutes ago, North Las Vegas is VFR…"). 65 to 75 min: says the report is late before the conditions ("The latest North Las Vegas report is 68 minutes old. As of then…"). Over 75 min: says it's stale and gives no category, conditions or verdict, matching the app ("There's no current METAR for North Las Vegas. The last report is 76 minutes old, about 15 minutes overdue."). Age is spoken in minutes under 2 h, then hours and minutes.

## 5-minute data (ASOS Updates)

5. **Warn, never reassure.** 5-minute values worse than the latest METAR (lower ceiling, lower vis, more wind) may be shown as a warning. Better values never change category, verdict or gust.
6. **Displayed gust** = the higher of the current METAR's gust and any 5-minute gust in the last 10 minutes, labeled by source. Display only: the verdict always uses the METAR gust (#1). A 5-minute ob with no gust means "gust not reported", never "no gust".
7. 5-minute data is labeled supplemental, not official: **"ASOS 5-min · supplemental"**, always with its observation time. Source: Synoptic (see Data source below).

## Pilot Notes

8. **Gust approach-speed additive (#20).** Half the gust factor (gust minus sustained), rounded up, from the METAR gust. Source: FAA Airplane Flying Handbook, FAA-H-8083-3C, Ch. 9 (turbulent air approach). One shared function for Pilot Notes and the crosswind calculator. Wording: "Gusty: consider +5 kt (½ gust factor, or per your POH)". The current "half the gust" formula is wrong (15G25 gives +12 instead of +5).
9. **Crosswind note floor.** Keep 5 kt. Below that, no Pilot Note; the runway display still shows the component.
10. **CFII item 6.** Missing-field notes are symmetric. Any missing safety-relevant field gets the same neutral "not reported" note.
11. **F17.** Observation-history lines show hazardous present weather: at minimum TS, SQ, FC (including +FC), GR, and freezing precipitation.
12. **PROB thunderstorms in the TAF headline.** Thunderstorms reach the headline at any probability, with probability and time ("PROB30 TSRA after 2 PM"). Non-convective PROB groups stay in the detail.

## Nearby-TAF fallback (Oct 16 addendum)

13. When the field has no TAF, use the nearest TAF within **50 nm**.
14. **Make the substitution impossible to miss** (Oct 21: ForeFlight's small distance label is easy to overlook, even for a 16-year user):
    - The forecast card's first line is the substitution, not a caption: "**No TAF for KVGT** · using **KLAS** (9 nm SW)". Same wording in the widget and Siri.
    - Every borrowed TAF gets the advisory treatment (dashed border, orange accent), so "not this field's data" always looks the same.
    - **No green/yellow/red for distance.** Those colors mean flight category and verdict; a green badge on a forecast would read as "VFR".
15. **Forecast accuracy and the Forecast Deviation Strip** compare the TAF station's forecast against **that station's own METARs**, labeled (e.g. "KLAS forecast vs KLAS actual"). They are never computed against this field's METAR.
16. **"Right now" row:** this field's current METAR beside the TAF station's. Warn-never-reassure applies: if this field is worse, show "Conditions here are worse than at the TAF site"; if it's better, say nothing.
17. **Distance tiers (wording, not color) and cautions:**
    - Up to 10 nm: the substitution line only.
    - Over 10 to 25 nm: add "TAF site 18 nm away. Local conditions may differ."
    - Over 25 to 50 nm: stronger caution text; distance repeated in the widget and Siri.
    - Over 50 nm: no TAF shown.
    - Elevation difference of 1,000 ft or more: "TAF site is N ft lower/higher", on top of any tier.
    - Mockup reviewed and approved Oct 20, 2026.

## Business model (launch) (revised Oct 21)

18. **Pro ships at launch**, in the first submission (reverses the Oct 20 "no IAP at launch"). Beta testers have had everything free since September; gating features after launch would read as taking them away. Small Business Program: enrolled. TestFlight testers get Pro via offer codes.
19. **Free forever:**
    - METAR/TAF decode, flight category, nearest, search, unlimited favorites.
    - Trend card, Forecast Deviation Strip, Pilot Notes (including the crosswind warning), density altitude, advisory weather.
    - **Crosswind calculator** (moved from Pro Oct 21: XW Calc is the free funnel for the same tool).
    - **Go/no-go verdict on the detail screen against the built-in starter profiles** (a couple of starters; no custom profile in the free tier). Starter verdicts are labeled with the profile, e.g. "GO vs VFR day starter", so they're never mistaken for the pilot's own minimums.
    - Safety-relevant information is never paywalled.
20. **Pro, one-time, $5.99, Family Sharing on:**
    - Home-screen and lock-screen widgets (including the verdict on widgets).
    - **Unlimited custom minimums profiles** (create, clone, edit).
    - Minimums alerts (airport watches, background checks, notifications).
    - Siri / Shortcuts.
    - Layout customization.
    - Apple Watch (when it ships).
    - Paywall copy shows what Pro adds, never what's withheld; the free app must feel complete.
    - Price check Oct 21 against aviation weather apps: AeroWeather Pro ~$4–5 one-time plus small subscriptions; AviatorWatch $9.99 up front; several competitors cap free airports at 1–3 (we don't).
21. **ASOS Updates:** a subscription that includes Pro, with a StoreKit introductory offer; the old 60-day first-launch free period is removed. **Price not yet set:** decide against the Synoptic cost and category norms (weather-app subscriptions run ~$5–9/yr; 5-minute data is unique, so a premium may be justified).
22. **XW Calc** becomes a free funnel into MetarMate. Its development is frozen.

## Data source for ASOS Updates

23. **Synoptic, paid plan** (decided Oct 21). Synoptic is issuing a ~7-day trial first; validation and build happen during it. MADIS is not being used.
24. The Synoptic token lives only on our proxy, never in the app. The proxy verifies the StoreKit purchase, caches each station ~5 min, and enforces quotas. Details and status: `docs/LAUNCH_CHECKLIST.md` section 6.

## Confirmation list (confirmed by Jeff, Oct 21, 2026)

- [x] #2 CHECK for unevaluated minimums, with no "back within minimums" alert
- [x] #3 VRB worst-case crosswind; CHECK when it decides the outcome
- [x] #4 Staleness: late at 65 min, no verdict over 75 min
- [x] #5–7 Warn-never-reassure (5-min data never turns NO-GO into GO), the displayed-gust rule, the label "ASOS 5-min · supplemental"
- [x] #8 ½ gust factor, with the stated wording
- [x] #9–12 5 kt crosswind floor, symmetric missing notes, F17 hazards in history, PROB TSRA in the headline
- [x] #13–17 Nearby-TAF: 50 nm cap (ForeFlight uses ~50 nm), substitution as the headline with advisory styling, 10/25/50 nm wording tiers, elevation caution
