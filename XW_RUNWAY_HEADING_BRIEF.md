# MetarMate — Use WMM Magnetic Runway Heading (not designator×10) in Crosswind Math

## The issue
The crosswind engine converts the METAR wind TRUE→magnetic (correct), but uses **designator×10** for the RUNWAY heading. Runway numbers are the magnetic heading rounded to nearest 10, so the runway side of the math carries up to ~5° error.

KVGT RWY 25, wind 210@10G18:
- Current (wind magnetic vs runway designator×10 = 250°): HW 6-11 kt.
- Correct (wind magnetic vs runway true→magnetic ≈ 258°): HW 5-9 kt — matches ForeFlight.
XW matches either way here (8-14); HW is off by the heading approximation. ForeFlight computes off the WMM-derived magnetic runway heading — that's what we match.

## The fix
Use the runway's TRUE heading from runways.json, converted to MAGNETIC via the existing MagneticDeclination (WMM) for the airport, as the runway heading in ALL auto crosswind/headwind math. Replace designator×10 with this.

### Critical — do NOT get this backwards
- runways.json leHdg/heHdg are TRUE headings (OurAirports _degT). VERIFIED earlier this session.
- The METAR wind is also TRUE and already converted to magnetic via MagneticDeclination for the airport lat/lon.
- Fix: convert the runway's TRUE heading to magnetic with the SAME declination already used for the wind, and use that. Both wind and runway then live in the magnetic frame via WMM — consistent, matches ForeFlight.
- Do NOT use designator×10 in the auto/Pilot-Notes crosswind path anymore.
- The MANUAL XWind tab KEEPS designator×10 (pilot types a runway number, no airport, no true heading available). Leave it unchanged.

### Where
- RunwayService.swift: wherever bestRunway()/crosswinds() derives runway heading as designator×10, change to: trueHeading(leHdg/heHdg from runways.json) → magnetic via WMM declination for the airport. Reuse the declination already computed for the wind conversion in this same path — don't recompute it differently.
- Convert the per-end true heading (leHdg for low end, heHdg for high end), not the designator. Slightly improves best-runway accuracy too.

## Must stay consistent
- The XW Pilot Notes restyle (range + arrow + colors) just implemented but NOT yet committed: after this fix its numbers update (KVGT HW becomes 5-9). Expected and correct. Commit the restyle AND this fix together (or this fix first).
- Arrow side (isLeft) must be computed in the SAME magnetic frame — recompute side off the magnetic runway heading so the arrow stays correct.
- Manual XWind tab UNCHANGED (designator×10). Verify it still behaves as before.

## Verify against ForeFlight
- KVGT RWY 25, wind 210@10G18: XW 8-14 kt, HW 5-9 kt (was 6-11). Matches ForeFlight.
- KSDL RWY 21: recompute, compare to ForeFlight — confirm near-zero case doesn't regress.
- A runway whose heading's last digit isn't 0 (designator×10 ≠ magnetic): confirm math now uses the magnetic heading, compare to ForeFlight.
- Best-runway SELECTION for KVGT still RWY 25 (selection is scale-invariant; confirm heading source change didn't flip the pick).

## Build / commit
- xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5
- Commit with the pending restyle: "Use WMM magnetic runway heading in crosswind math (was designator×10); matches ForeFlight on XW and HW". Or heading fix first, then restyle.
- No # in terminal commands; single-line.

## Files
- MetarMate/Services/RunwayService.swift (heading source: true→magnetic via WMM, reuse existing declination)
- MetarMate/Services/MagneticDeclination.swift (reuse, no change expected)
- DO NOT TOUCH: CrosswindTabView / CrosswindKeypadView (manual tab stays designator×10)
