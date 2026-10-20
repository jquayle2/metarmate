# Handoff — MADIS 1-minute ASOS research spike

**Repo:** `/Users/jquayle/code/xcode/MetarMate`
**Branch:** create `spike/madis-omo` off `main`. Do not touch the audit or trend-spine branches.
**Type:** research + throwaway prototype. **No changes to any Swift source, the Xcode project or Android.** Nothing is deployed.

## Why we're doing this

MetarMate's paid "ASOS Updates" subscription shows 5-minute ASOS data. Today that comes from Synoptic Data (`MetarMate/Services/SynopticService.swift`), and Synoptic has offered a $100/month starter commercial plan. Synoptic gets this data from NOAA MADIS, whose "1-minute ASOS" (OMO) dataset is marked unrestricted / publicly accessible.

We want to know whether MADIS, or another free NOAA source, can replace Synoptic (or serve as a fallback) behind a future MetarMate proxy server. The output of this spike is a written recommendation backed by real data, not production code.

## Known facts (verify, don't assume)

- OMO dataset page: https://madis.ncep.noaa.gov/madis_OMO.shtml
  - CONUS only.
  - Hourly netCDF files; the current and previous hour are reprocessed every 5 min.
  - "No restrictions."
  - OMO "should not be considered METAR observations".
- OMO variable list: https://madis.ncep.noaa.gov/sfc_OMO_variable_list.shtml. Includes:
  - T, TD, altimeter
  - wind dir/speed/gust
  - VIS
  - sky cover + layer bases
  - present weather
  - RVR
  - density altitude
  - per-sensor status flags
- Public sample files (no account): https://madis.ncep.noaa.gov/sample_data/software/sampledata/LDAD/OMO/netCDF
- Distribution services: https://madis-data.ncep.noaa.gov/
  - Access methods: FTP, OPeNDAP, LDM, and a Text/XML Viewer for on-demand use.
  - Real-time access normally needs a free account via https://madis.ncep.noaa.gov/data_application.shtml. **Jeff is submitting that application in parallel.** You cannot do it.
- Synoptic's description of the same data: https://docs.synopticdata.com/services/high-frequency-asos
  - Lower precision; wind is a 2-min average.
  - ASOS only, not AWOS.
  - Usually 2–5 min latency.
- Third candidate to test: `https://api.weather.gov/stations/{ICAO}/observations`. It may already carry ~5-min ASOS obs for some stations as free per-station JSON, which would remove the need for any file ingest. It requires a descriptive `User-Agent` header, e.g. `MetarMate-research (jquayle2 on GitHub)`.

## Questions this spike must answer

| # | Question | Per source |
|---|---|---|
| Q1 | **Access** — what works anonymously vs. needs an account; which methods actually carry OMO (HTTPS, FTP, OPeNDAP, Text/XML)? | MADIS |
| Q2 | **Content** — which fields are present and populated per station, and do they cover everything ASOS Boost currently displays? | all |
| Q3 | **Freshness** — observation time vs. time available to us (measure, don't quote docs) | all |
| Q4 | **Coverage** — which stations within ~100 nm of KVGT have 5-min data, ASOS vs. AWOS | all |
| Q5 | **Agreement** — values vs. Synoptic and vs. the official METAR (aviationweather.gov) at the same time | all |
| Q6 | **Ops cost** — file sizes/volume per hour, ingest effort, rate limits, rough hosting cost for a small proxy | all |
| Q7 | **Terms** — redistribution in a paid app, attribution, NOAA notification requirement | all |

## Phases

### Phase 0 — prep (stop and show me your plan before writing files)
1. Run `git status`. If the tree is dirty, **stop and ask**; don't stash or discard anything.
2. Checkout `main`, pull, create `spike/madis-omo`.
3. Read `SynopticService.swift` and the ASOS Boost UI code. List every field the app actually consumes from Synoptic. This becomes the target field map for Q2.
4. Propose the plan and file layout. Wait for my go-ahead.

### Phase 1 — no-account work
1. **Sample OMO parse.**
   - Set up a Python venv in `tools/madis/.venv` (gitignored).
   - Download the public OMO samples.
   - Write `tools/madis/omo_dump.py`: per station, dump JSON with ICAO, obs time, wind dir/speed/gust (kt), vis (SM), sky layers (ft AGL), present weather, altimeter (inHg), temp/dew (°C), and QC/sensor-status flags.
   - Document station ID format, time encoding, units and fill values.
2. **api.weather.gov cadence.**
   - For KLAS, KVGT, KHND, KPHX, KSLC plus 3–4 smaller fields within 100 nm of KVGT (mix of ASOS and AWOS), pull the last 6 h of observations.
   - Report the interval between obs and which fields are populated on the off-hour obs.
3. **Live side-by-side logger.** `tools/madis/compare_sources.py` polls every 5 min:
   - Synoptic (current endpoint/params from `SynopticService.swift`)
   - api.weather.gov
   - aviationweather.gov METAR

   For the same stations, log to CSV: source, station, obs time, fetch time, latency, wind, gust, vis, ceiling, altimeter. Run it for at least 2 hours and summarize.
4. **Access probe.** Without credentials, test which MADIS distribution URLs/methods return OMO data and which demand login. Record exact URLs and HTTP status codes.

### Phase 2 — after Jeff has MADIS credentials (he'll tell you)
1. Pull real-time OMO through the best available method. Add MADIS as a source in `compare_sources.py`.
2. Run the logger for 24 h if possible (use `nohup` or `caffeinate`; tell Jeff how to stop it). Measure Q3 and Q5 properly.
3. Check whether the Text/XML Viewer can serve OMO per station on demand. That would let a proxy skip netCDF entirely.

## Deliverables

- `tools/madis/` containing:
  - the scripts
  - `README.md` with exact run commands
  - `requirements.txt`
  - `.gitignore` covering `.venv` and data
- `docs/research/MADIS_ASOS_findings.md`. Contents:
  - Answers to Q1–Q7 with evidence (URLs, sample output, CSV summaries).
  - Decision matrix — Synoptic vs. MADIS netCDF ingest vs. MADIS Text/XML vs. api.weather.gov — scored on freshness, coverage, completeness, reliability, effort and cost.
  - Recommendation for the proxy's primary and fallback source.
  - Open questions for Mike: data labeling ("supplemental, not official") and how to handle fields that disagree with the METAR.
- Raw logs: commit only a small representative excerpt; keep full CSVs out of git.

## Rules

- **Planning first.** Propose before writing files; flag anything out of scope before doing it.
- **Synoptic token.** Read it from the env var `SYNOPTIC_TOKEN`. If unset, ask Jeff to export it. Never print it, log it, put it in a URL in any output, or commit it.
- **Commits.** Commit per logical unit on `spike/madis-omo`, staging specific paths. Show the diff summary before each commit, and report hashes when done. **Ask before pushing.**
- **Commands for Jeff.** Any command you give Jeff to run: single line, `&&`/`;` chained, no `#` characters anywhere.
- **Ground truth.** Validate every unit conversion against the official METAR for the same station and time. Flag any mismatch rather than "fixing" it to agree.
- **Scope.** No edits under `MetarMate/`, no Xcode builds, no Android, no proxy implementation. Those come after the recommendation.
- **Stop and ask** if:
  - MADIS terms appear to forbid display in a paid app,
  - sources disagree on safety-relevant fields (ceiling, vis, gust) by more than METAR rounding, or
  - any step would need credentials you don't have.
