# MetarMate — Future Enhancements

Queued ideas not yet scheduled into the active build plan. Each entry notes its status and dependencies.

---

## Personal Minimums Verdict — Detail Banner + Badge

**Status:** Not yet implemented. Queued after Steps 4–5 (notification engine + UI) ship. Builds directly on the `GoNoGoEvaluator`.

**What it is:** Surface the pilot's personal go/no-go verdict (from the active `MinimumsProfile`) as ambient UI, so the app continuously answers "can I fly to my minimums here" without setting up a watch or waiting for a notification. **Differentiator:** competitors color airports by regulatory flight category (same for everyone); nobody colors by the individual pilot's personal minimums.

### Phase 1 — Detail tab only (build first)

- A prominent **verdict banner** at top of the airport detail page, in the plain-language, color-coded style of the XW Calc tailwind/crosswind warning (bold, instant read, states verdict + limiting factor). Reference: XW Calc keypad screen banner.
- **Pilot Notes card shows the reasons** — reuse the `GoNoGoEvaluator` verdict's existing per-factor detail (which factors drove a NO-GO). Already built for the notification body; just surface it here. e.g. *"NO-GO: crosswind 15kt on best runway (07) exceeds your 12kt minimum; ceiling and visibility OK."*
- **Low risk:** one airport, weather already fetched by the detail view, near-zero added cost.

### Phase 2 — Nearest/Favorites list badge (later, only if Phase 1 proves valuable)

- Extend the verdict to a per-row **badge** on the airport list.
- **PERFORMANCE:** must reuse the batch METARs the nearest list already fetches — **NEVER per-row network calls** (that's the trap). The crosswind math itself is trivial (a few mults + sin per runway); the only real cost is weather data, which the list already has.

### Crosswind early-out optimization (applies to both phases)

- Crosswind ≤ total wind speed always (crosswind = windSpeed × sin(angle), sin maxes at 1.0). So if gust (or sustained if no gust) ≤ the crosswind minimum, **skip the runway lookup + trig entirely** — even worst-case perpendicular wind can't breach the limit. Short-circuit to "crosswind OK" on one comparison.
- Use **GUST** for the comparison, not sustained (consistent with the engine). Example: `16G26` compares against 26.
- Only short-circuits the **GO** direction. A NO-GO still needs full runway math (the best runway may bring an over-limit total wind under — the KVGT case). But calm days are the majority, so this is a large average win and makes the Phase 2 list badge's cost scale with "how many airports are windy now," not list length.

### Open design question — banner color (respect MetarMate color rules)

MetarMate rules: category colors (VFR/MVFR/IFR/LIFR) reserved for flight category; amber for wind cautions; red borders **ONLY** for IFR/LIFR/TS. XW Calc uses red for crosswind warnings, but that would violate MetarMate's rules if the NO-GO is crosswind-driven (not an IFR condition). Decide a deliberate color scheme for the personal-minimums banner that doesn't dilute the IFR-red signal — likely amber-family for wind-driven NO-GO, reserving red for when an actual IFR/TS factor is the cause.


---

## Performance Section Redesign — TO/Landing Distance + Climb (Research + Plan)

**Status:** Math researched and validated against sources (Jul 7 2026). Not yet built.

### The problem with the current Performance section
Shows calculation *inputs* pilots don't act on, and lists DA twice:
- Density Altitude appears in both the collapsed header AND the expanded stat block (redundant).
- ISA Deviation (+29°C ISA) — rarely operationally used by GA pilots; it's an intermediate value.
- DA Penalty (+3,482 ft above field) — intermediate value, not an action.
- "~18% power loss" stands out as useful BUT is misleading alone: it does NOT mean 18% more
  runway or 18% less climb. Power loss ≠ distance/climb penalty (those are larger and non-linear).

Goal: surface operational CONSEQUENCES (how much more runway, how much less climb), not inputs.

### The math (rules of thumb — validated against multiple sources)

Multiplicative model, chained on POH base distance:
`Distance = Base × DA_factor × Wind_factor`

**Density Altitude:**
- Takeoff roll: +10% per 1,000 ft DA (normally aspirated). Some sources: +10%/1000 up to
  8,000 ft, then +15%/1000 above 8,000. Citation/turbine sources use flat 15%. Use 10% mainstream,
  optional 15% >8,000 ft.
- Landing roll: ~+10% per 1,000 ft DA as well (softer in reality; higher TAS at touchdown is the
  penalty, no engine-power term). Field-elevation rule alt: +4%/1000 ft stopping.
- `DA_factor = 1 + 0.10 × (DA / 1000)`

**Wind (asymmetric — tailwind penalized much harder than headwind helps):**
- Headwind (favorable): reduce ~1.5–2% per knot. (1.5%/kt up to 20 kt; or Cessna 10% per 5 kt = 2%/kt.)
  `Wind_factor = 1 − 0.0175 × HW_kt` (1.75%/kt midpoint)
- Tailwind (unfavorable): +10% per 2 knots = 5%/kt. 5 kt TW ≈ +25%, 10 kt TW ≈ +55%.
  `Wind_factor = 1 + 0.05 × TW_kt`
- Regulatory basis (50/150 rule): use max 50% of headwind, 150% of tailwind in perf calcs.
- Wind component = runway-axis headwind/tailwind = windSpeed × cos(angle) — ALREADY computed in
  the XWind view (`headwind`/`gustHeadwind`). Positive → HW (reduce), negative → TW (penalize steeper).

**Climb (separate from distance):**
- Fixed-pitch NA: climb performance −8% per 1,000 ft DA. Variable-pitch NA: −7% per 1,000 ft DA.
- Engine HP loss (NA): −3.5% per 1,000 ft DA (this is the "18% power loss" number — NOT the same
  as distance/climb penalty; keep it clearly secondary/informational).

### Display direction (to design)
- Lead with consequences: "+X% takeoff roll", "+Y% landing roll", "−Z% climb" as the headline,
  not DA/ISA/penalty inputs.
- Show DA + wind contributions separately, then a combined total (product of factors as % delta).
- Takeoff and landing get SEPARATE readouts (different wind coefficients; TO also carries climb).
- Base distance: either user-input (per aircraft, e.g. from profile) OR show pure % deltas if no base.
  Note: `da.takeoffRollText` already exists in code (currently buried tertiary text) — reuse.
- Honesty caveat stays: rule-of-thumb estimate, verify against POH/AFM. FAA is emphatic POH is
  authoritative.

### Redundancy to cut
- DA shown once, not twice.
- Drop or demote ISA Deviation and DA Penalty from the primary view (move to an expandable "details"
  if kept at all).
- Reframe power loss as secondary informational, not a headline number.


---

## Advisory Weather — Multi-Day Forecast (Design Discussion, Parked)

**Status:** Design discussion only. Not built. Parked to review with Sara.

### Context
ForeFlight's "Daily" tab shows a 7–10 day civilian forecast (NWS/MOS) with day/night
temps, precip %, icon, and an hourly drill-down that surfaces per-hour flight category,
ceiling, visibility, wind, temp, density altitude.

MetarMate's Advisory Weather already does a 6-HOUR version of this (Open-Meteo): 6-hr
trends (pressure/wind/T-D/vis) + a 6-hr forecast strip with per-hour wind/gust/sky/temp
and a green/amber/red flyability dot. So this is EXTENDING the horizon of an existing
pattern, not building from scratch.

### Data reality
- `OpenMeteoService.buildURL` currently requests only `forecast_hours=6` and does NOT request
  the `daily` block.
- Open-Meteo supports up to 16 forecast days + a rich `daily` block (temp max/min, weathercode,
  precip sum/probability, wind max, sunrise/sunset). Same free CC-BY-4.0 source, no new API cost.
- Open-Meteo will NOT give MOS-derived flight categories per future day like FF. We'd DERIVE a
  rough advisory flyability (green/amber/red) from daily max wind, weathercode, precip — same
  approach as the existing 6-hr strip, but coarser and further out.

### Design directions mocked (see chat)
- A — Daily strip: extend the 6-hr card, each cell = a day (dot, hi/lo temp, wind, one-word sky), swipeable.
- B — Flyability-first rows: vertical list, dot-led, plain-language sky+wind+temps, tap row → that day's hourly.
- C — Pattern summary + strip: plain-English sentence ("Best flying window Wed–Sat … T-storms Sunday")
  over a compact colored week-strip. Most "thinks like a pilot".

Leaning: C's summary sentence + B's tappable rows (mirrors the TAF hero move — interpretation up top,
detail on demand). Decide with Sara.

### Hard design constraints
- Cap display at 7 days even though API allows 16 — accuracy craters past ~7; showing noise as
  signal cuts against the "thinks like a pilot" ethos.
- Flyability dot at day-level is the hard part and will be wrong sometimes — honesty framing
  ("estimated · trip-planning aid, not a briefing") must be prominent, especially far-out days.
- Reuses existing Advisory Weather visual language (green/amber/red dots, card strip).

### Build scope when greenlit (rough)
1. `OpenMeteoService`: add `daily` vars + `forecast_days` (7) to the request; decode a new daily block.
2. New model: `AdvisoryDailyDay` (date, tempMax/Min, windMax, gustMax, weathercode→sky, precipProb, derived flyability).
3. New flyability-derivation fn for day-level (analogous to the 6-hr one).
4. New UI section in the advisory detail view (design per A/B/C decision).
