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
