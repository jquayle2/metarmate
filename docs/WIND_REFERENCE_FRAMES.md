# Wind Reference Frames — True vs Magnetic

> Why this matters: crosswind math is only correct if every wind and every runway heading is in
> the SAME reference frame. MetarMate ingests TRUE-north data and converts to MAGNETIC for display
> and runway math, because magnetic is the frame pilots actually fly (ATIS, runway numbers, diagrams).

## The one rule
- **Machine-readable wind/heading data → TRUE → convert to magnetic via WMM.**
- **Anything a human reads or hears (ATIS, tower, runway numbers, diagrams) → already MAGNETIC.**

## TRUE north
- **METAR** wind (dddff group, e.g. `21010KT`) — TRUE. Foundational source for the app.
- **TAF** forecast wind — TRUE.
- **Winds aloft / FB / FD** forecasts — TRUE.
- **METAR remarks** (PK WND, WSHFT) — TRUE (part of the coded METAR).
- **NWS/NOAA gridded & model winds** (advisory weather) — TRUE.
- **ASOS/AWOS DATA FEED** (Synoptic, NOAA API) — TRUE. The sensor measures true; only the VOICE
  broadcast is converted to magnetic. **Trap:** when ASOS 5-min is re-enabled, that data is TRUE,
  same path as METAR.
- **D-ATIS** at ~57 large airports — TRUE (digital ATIS). Does not affect the app (we read METAR).

## MAGNETIC
- **ATIS** (spoken/standard) — MAGNETIC.
- **AWOS/ASOS VOICE broadcast** (radio/phone) — MAGNETIC (synthesized from the true sensor data).
- **Tower / approach / ground** controller-issued winds — MAGNETIC.
- **Runway numbers / designators** — MAGNETIC, rounded to nearest 10°, and they LAG variation drift
  over decades (a runway numbered 25 can sit at ~256° magnetic).
- **FAA airport diagram heading numbers** — MAGNETIC (chart notes the variation separately).

## Data we rebuilt (neither-until-converted)
- **runways.json `leHdg`/`heHdg`** — TRUE. Source: FAA NASR `TRUE_ALIGNMENT` where surveyed,
  OurAirports computed-true as fallback, designator×10 last resort. Converted to magnetic in RunwayService.
- **NASR `TRUE_ALIGNMENT`** — TRUE (in the field name).

## How RunwayService uses this (auto / Pilot Notes path)
1. Compute WMM declination once from the airport lat/lon.
2. Rotate the TRUE METAR wind to magnetic (true − declination).
3. Rotate each runway's TRUE heading (from runways.json) to magnetic (true − declination).
4. Do crosswind/headwind math in the magnetic frame. Arrow side (isLeft) computed in this frame.
5. Result matches ATIS winds, runway numbers, FAA diagrams, and ForeFlight.

Validated: computed magnetic vs published FAA diagrams is exact at variation extremes
(KSEA 16°E, KBOS 15°W) and within ~2° (rounding) at KVGT/KLAS.

## The deliberate exception: manual XWind tab
The manual calculator (CrosswindKeypadView / CrosswindTabView) does **NOT** convert. The pilot types
in winds they HEARD from ATIS/tower (already magnetic) against a runway number (magnetic), so it uses
designator×10 with no WMM conversion. Converting it would double-correct.

## Sanity check (KVGT, var ~11.7°E)
- METAR `21010KT` → 210° TRUE → ~198° MAG.
- RWY 25 true 268° → ~256° MAG (diagram shows 254°).
- Crosswind/headwind computed between 198° wind and 256° runway → matches ForeFlight.
