# Handoff — Airport Name Refresh from NASR (airports.json)

**Created:** June 30, 2026 (evening session)
**For:** a fresh chat to pick up and finish
**Project root:** `/Users/jquayle/code/xcode/MetarMate`
**Related doc:** `/Users/jquayle/code/Pi/MetarMate_Project_State.md` (session state anchor)

---

## Origin / why this exists

During redesign review, Jeff flagged the airport-name header ("Las Vegas/North
Arpt, NV, US") as too large — it wraps to 3 lines and dominates the detail view.
Root cause: `airports.json` (OurAirports-derived) stores mangled display names —
`City/Field, ST, US` concatenations. ForeFlight shows clean names ("North Las
Vegas," "Harry Reid International"). We confirmed FF's source: FAA **NASR
`APT_BASE.csv`, column `ARPT_NAME`** — the official facility name. Jeff already
downloads this exact file for the runway pipeline, so the clean names are
available in a file the project already parses.

This is a DATA-PIPELINE change (touches the core `airports.json` every screen
depends on), deliberately separated from the redesign PR. It is NOT the quick
display fix — see "Two tracks" below.

## Two tracks (keep separate)

- **Track 1 — the immediate "name too big" fix (display-side, NOT this handoff).**
  Drop the ", US" country tail (every airport in the DB is US), optionally the
  state, keep type readable. Independent of the data work; can ship anytime.
  Four mockup options were explored: (A) just shrink font, (B) drop ", US",
  (C) split field-name headline + quiet city/state line, (D) cap 2 lines +
  ellipsize. Recommendation was B or B+C. Must hold at larger Dynamic Type sizes
  (app DOES scale with the iOS slider — see project state doc).

- **Track 2 — THIS handoff: refresh the names in `airports.json` from NASR.**
  Gets clean FF-style names across the whole US database, plus separate
  `city`/`state` fields (which also unlock the Track-1 option-C split layout).
  Refreshes free on the existing 28-day NASR cadence.

## What's already done (this session)

A working script exists on disk:
`/Users/jquayle/code/xcode/MetarMate/tools/nasr/merge_airport_names.py`

It reads NASR `APT_BASE.csv` (same file `merge_runways.py` uses), pulls
`ARPT_NAME` / `CITY` / `STATE_CODE`, title-cases + optionally expands
abbreviations (INTL→International etc.), and merges clean `name` (+ `city`,
`state`) into `airports.json` keyed by ICAO→stripped-K-LID→bare-LID→IATA.
No-match airports keep their OurAirports name. lat/lon/elev/iata/hasMetar
untouched. Writes to a `--out` path (we used `airports.json.new`) so the live
file is never modified until reviewed.

Test run (NASR 2026-06-11 subscription, `--title-expand`):
```
NASR names loaded: 2670 by ICAO, 13040 by LID
Merged: 4904 refreshed, 9849 kept OurAirports fallback
```
Majors/Class-D validated and match ForeFlight: North Las Vegas, Harry Reid
International, Henderson Executive, Nellis AFB, Boulder City Municipal,
Scottsdale, Centennial, Falcon Field, Addison, Palo Alto, Kingman.

## Open issues to fix BEFORE any file swap

1. **Low match rate (~4,904 of ~14,753).** NASR has 2,670 ICAO but 13,040 LID
   entries; `airports.json` is keyed by 4-char ICAO. Most US GA/Class-D fields
   have no ICAO — only a LID — so they miss. The airports that matched mostly
   have ICAOs. Result today: majors read clean, ~10k small fields still show the
   old mangled name — arguably WORSE (inconsistent) than uniform mangling.
   → Improve LID/IATA matching. Figure out how `airports.json` keys pure-LID
   airports (36K, 0L7) and match NASR `ARPT_ID` against that. K36K currently
   comes back "not found" in validation — same LID-vs-ICAO issue.

2. **Titleizer bugs (visible in sample, some names now look WORSE than old):**
   - No capitalization after `/`, `'`, `-` inside a token:
     "Hartsfield/**j**ackson", "Chicago O'**h**are", "Boeing Fld/**k**ing County",
     "Gwinnett County/**b**riscoe", "Ely/**y**elland", "Big Spring/**mc** Mahon".
   - "Mc"/"Mac" not handled: "Mc Clellan-Palomar", "Mc Mahon".
   → Fix `titleize()` to capitalize after separators and handle Mc/Mac/O'.

3. **Some NASR names are LONGER than old ones** (KBOS "General Edward Lawrence
   Logan International", KRHV "Reid-Hillview Of Santa Clara County").
   → RESOLVED — do NOT build a length cap or "prefer shorter form" heuristic.
   Confirmed via ForeFlight screenshot: FF uses the full official NASR name and
   simply truncates with an ellipsis when it doesn't fit ("KSMX: Santa Maria
   Pub/Ca…", "KSNA: John Wayne/Orange…"). Match that behavior:
   - Keep the full NASR `ARPT_NAME` verbatim in the data.
   - LIST rows (nearest/search/favorites/alerts): `.lineLimit(1)` +
     `.truncationMode(.tail)`. FF-style single-line ellipsis.
   - DETAIL header: allow up to 2 lines then ellipsize (mockup option D — which
     is exactly what FF does). Dropping ", US" (Track 1) + the clean NASR name
     usually fits 1-2 lines without truncating; truncation is just the safety
     net for long outliers. Full name available on tap if desired.
   This removes the only open design decision — no per-airport tuning needed.

4. **Validation coverage.** Before swapping, run a broad diff (not just the
   6-airport spot check) — sample by category (Class B/C/D, GA, LID-only),
   count how many changed, eyeball a few hundred for new mangling. Confirm the
   `.new` file still round-trips (same record count, no dropped fields).

## Suggested next-session plan

1. Read this handoff + the project state doc. Confirm NASR CSV still at
   `/Users/jquayle/Downloads/28DaySubscription_Effective_2026-06-11/CSV_Data/nasr_csv/`
   (or Jeff's current download).
2. Fix `titleize()` (issue 2). Re-run, re-check the sample.
3. Fix LID/IATA matching (issue 1). Re-run, confirm match rate jumps and
   pure-LID airports (36K, 0L7) resolve. Report new matched/unmatched counts.
4. Decide the long-name policy with Jeff (issue 3).
5. Broad validation pass (issue 4). Show Jeff a large sample.
6. Only then: swap `airports.json.new` → `airports.json`, build-test
   (`xcodebuild -scheme MetarMate ... build`), commit + push.
7. Consider adding this as a documented step in the 28-day NASR refresh runbook
   so names refresh alongside runways. Update `MetarMate_Project_State.md`.

## Conventions (Jeff's prefs)
- No `#` in terminal commands (breaks his terminal); chain with `&&` or `;`;
  single-line commands only.
- Prefers artifacts / str_replace edits over paste-the-code.
- Commit incrementally: `git add -A && git commit -m "..."` single line.
- Validate ground truth (ForeFlight, NASR, FAA diagrams) before committing.
- Work via Desktop Commander on JAQ-Studio-Mac; write briefs, Claude Code
  implements the app-side; data scripts like this one can be run directly.

## Files
- Script: `tools/nasr/merge_airport_names.py` (on disk, working, needs the 2 fixes).
  NOTE: repo `.gitignore` line 6 is `*.py`, so this script is IGNORED by default.
  The existing NASR scripts (merge_runways.py etc.) were force-added. When ready to
  commit, use `git add -f tools/nasr/merge_airport_names.py`.
- Handoff: `tools/nasr/HANDOFF_airport_names_nasr.md` (this file, untracked).
- Live data: `MetarMate/Resources/airports.json` (keys: icao, iata, name,
  latitude, longitude, elevation, hasMetar) — UNCHANGED, do not swap yet.
- Test output `airports.json.new` from this session was DELETED (throwaway; the
  script regenerates it). Regenerate with the command in "Suggested next-session plan".
- NASR source: `.../APT_BASE.csv` cols used: SITE_TYPE_CODE(='A'), ICAO_ID,
  ARPT_ID, ARPT_NAME, CITY, STATE_CODE.

## Branch / commit note
This work is SEPARATE from the redesign PR. The redesign lives on branch
`design/metarmate-refresh` (PR #1). Do NOT commit the airport-name data work onto
that branch. Start this on its own branch off `main` (or commit to `main`) so the
two efforts stay independent. The script + handoff were intentionally left
uncommitted at the end of the originating session for this reason.
