# MADIS / 5-minute ASOS findings

Spike brief: `docs/handoffs/MADIS_spike_handoff.md`. Branch `spike/madis-omo`.
Status: **Phase 1 in progress.** Sections marked *pending* haven't been measured yet.

All times are UTC. Station ASOS/AWOS types come from FAA NASR `AWOS.csv` (28-day subscription effective 2026-06-11).

---

## Phase 0 findings (app code, read-only, no fixes)

### P0-1. Fields MetarMate consumes from Synoptic (target map for Q2)

Request: `MetarMate/Services/SynopticService.swift:23-31` (`latest`, `within=60`, used by alerts) and `:42-50` (`timeseries`, `recent=360`, used by the detail view). Both use `units=english`.

| App field | Synoptic var | Consumers |
|---|---|---|
| observationTime | `date_time` | age label, alert timestamp |
| windDirection (°true, nil = VRB) | `wind_direction` | decoded wind, wind strip, XW calc, wind-shift delta, alerts |
| windSpeed (kt) | `wind_speed` | decoded wind, wind strip, XW, METAR delta, alerts (nil → 0 kt) |
| windGust (kt) | `wind_gust` | as above + "Gusts developed" delta |
| visibility (SM) | `visibility` | decoded vis, category, vis delta, alerts (nil → 10 SM) |
| cloudLayers ≤3 (cover + ft AGL) | `cloud_layer_1..3_code` | layer list, ceilingAGL, ceilingCoverage, estimatedCategory, alerts |
| skyConfirmedClear | layer-1 CLR/SKC | category VFR vs unknown |
| temperature / dewpoint (°F, shown °C) | `air_temp`, `dew_point_temperature` | T/Td row |
| altimeter (inHg) | `altimeter` | altimeter row |
| weatherCondition | `weather_condition` (derived `_1d`) | present-wx row |

`sea_level_pressure` is fetched but never displayed. The wind strip shows the last 12 obs (`WeatherDetailView.swift`, `asosWindStrip`), so the cadence needs to be 5 minutes to cover an hour.

### P0-2. Synoptic `units=english` wind units: knots (my earlier flag was wrong)

During Phase 0 I suspected `units=english` might return mph. **Synoptic's public docs say it returns knots.** The Time Series page (https://docs.synopticdata.com/services/time-series, fetched 2026-10-20) says, under `units`:

> speed (mps, mph, kph, kts) … to use "english" units with any speed variables in mph (instead of default knots) the parameter would be &units=english,speed|mph

- Request: `SynopticService.swift:29` and `:47` (`"units": "english"`).
- Consumption: the model comments `SynopticService.swift:265-266` (`// knots`). No conversion is applied anywhere. The values are used as knots directly, for example `AlertConditions.swift` `init(from:)` and `WeatherDetailView` wind/XW.
- I found no saved Synoptic response, fixture or `UNITS` block in the repo. Only `SynopticService.swift` mentions Synoptic.
- Conclusion: the docs support knots, so this isn't a bug. It hasn't been checked against a live response, because there's no working token. The docs don't give `english` defaults for visibility or altimeter. The app assumes SM and inHg, which is unverified.

### P0-3. Behaviour on auth failure / expired token

A live probe (2026-10-20, fake token, no credentials) shows Synoptic returns **HTTP 401** with the body `{"SUMMARY": {"RESPONSE_CODE": 2, "RESPONSE_MESSAGE": "Invalid token. …", "HTTP_STATUS_CODE": 401}}`. With no token at all it returns 401 "Missing token".

Code path (line numbers on `main`):
1. `SynopticService.swift:76-77`: non-200 throws `SynopticError.httpError(401)`. A 200 response with `RESPONSE_CODE != 1` would throw `apiError` at `:82-83`.
2. `WeatherViewModel.swift:211-214`: on failure, sets `synopticError = "ASOS data unavailable for this airport."` and clears `synopticLatest` and `synopticHistory`.
3. `WeatherViewModel.swift:37`: `hasASOSData` is false, so the gate at `WeatherDetailView.swift:36` fails and the section isn't rendered.
4. **`synopticError` is never read by any view.** The result is **silent: no section, no message.** It never shows stale or fabricated data.
5. Alerts: `AlertPipeline.swift:121` uses `try?`. The failure is swallowed, and the station silently uses METAR (`source: .metar`).

Adjacent risk: `SynopticService.swift:108` uses `?? Date()` for a missing `date_time` in the `latest` parse. A 200 response with a station but no observations would produce an obs stamped "now" with nil fields. Alerts would then read that as calm wind and 10 SM (`AlertConditions.swift` fallbacks) with a fresh timestamp. This doesn't happen on auth failure (that path throws), but it is a "looks valid" path.

### P0-4. Which gate hides ASOS on Jeff's device

Every gate fails the same way on screen (no section, no teaser, no error), so the UI can't tell you which one fired. It depends on the build:

| Build | Gate | Effect |
|---|---|---|
| 21 (`feat/trend-time-spine`, includes `79c352c`) | `StoreManager.swift:46-47`: `isAsosUser = FeatureFlags.asosAvailable && (…)`; `FeatureFlags.swift:11` `asosAvailable = false` | `isAsosUser` is always false. No fetch (`WeatherViewModel.swift:92`), section gate fails (`WeatherDetailView.swift:41`), teaser blocked by the flag (`:43`). Token and free window are never consulted. |
| ≤20 / `main` (build 18), window lapsed | `StoreManager.swift:38-40` (60 days from `metarmate_first_launch_date`), `:44-45` | no fetch, no section; teaser blocked by flag (`WeatherDetailView.swift:38`) |
| ≤20 / `main`, still in window | fetch runs, gets 401 | silent hide via P0-3 |

### P0-5. Other app notes (not fixed)

- `SynopticObservation.temperatureCelsius/dewpointCelsius` use `Int(...)`, which truncates toward zero instead of rounding. For example, 28.9 °C displays as 28. Q5 compares raw source values, so this app-side ±1 °C issue is recorded separately and not counted as source disagreement.
- The Synoptic API token is hardcoded in `SynopticService.swift` and is in git history. It's expired according to Jeff. Not reproduced here.

---

## Q1. Access

### MADIS, anonymous (no account)

The MADIS web host `madis.ncep.noaa.gov` (Akamai, `sancert.weather.gov.edgekey.net`) was **unreliable** during 2026-10-20 02:57–03:22Z. Per-request timestamps weren't captured for these early probes. The times below are bounded by file mtimes and the order of the session. From here on the probes log their own timestamps.

| ~Time (Z) | URL | Result |
|---|---|---|
| 02:57–03:01 | `https://madis.ncep.noaa.gov/sample_data/software/sampledata/LDAD/OMO/netCDF/` | **403** (199-byte Apache "Forbidden") |
| 02:57–03:01 | `https://madis.ncep.noaa.gov/madis_OMO.shtml` | **504** |
| 02:57–03:01 | `https://madis.ncep.noaa.gov/sfc_OMO_variable_list.shtml` | **504** |
| ~03:03 | `https://madis.ncep.noaa.gov/` (`curl -6` and default) | TLS ok, then **no bytes in 20–60 s** (timeout) |
| ~03:03 | `https://madis.ncep.noaa.gov/madis_OMO.shtml` (`curl -4`) | 200 in 2.7 s; the same request over IPv6 timed out at 60 s |
| ~03:04 | same, 3× IPv4 with and without User-Agent | 000(40 s timeout), 200, 200, 200, 200, 200 (0.5–8.7 s). Flaky, not UA-dependent |
| 03:05 | `madis_OMO.shtml`, `sfc_OMO_variable_list.shtml`, `madis_restrictions.shtml` | 000 (60 s timeout) each; `data_application.shtml` 200 |
| 03:06–03:08 | same doc pages with retries | 200 on try 2–3 |
| 03:09 | `…/sampledata/LDAD/OMO/netCDF/` | **403 × 6** |
| 03:10 | `https://madis.ncep.noaa.gov/sample_data/` | 200 (directory index lists only `software/`) |
| 03:10 | `https://madis.ncep.noaa.gov/madis_sample_data.shtml` | 000 (timeouts) on every try |
| 03:10 | `…/sample_data/software/sampledata/LDAD/` | 403 |
| ~03:21 | `…/sample_data/software/` | timeouts (Jeff observed them; the walk was stopped) |

Findings:
- **The documented public OMO sample directory returns 403 to anonymous requests.** Directory listing is forbidden. Individual filenames are unknown, so files couldn't be tried directly.
- The doc pages work intermittently: 504s and long stalls, and IPv6 hangs after TLS. A proxy hitting this host needs short timeouts and should prefer IPv4.
- `madis-data.ncep.noaa.gov` (distribution) wasn't probed before the stop.
- The documented sample directory is still unusable. The single end-of-phase retry (03:31:41Z, `access_probe.py`) got **503** on all 3 attempts. The OMO sample parse was instead done on the public hfmetar directory below.

Access probe, 2026-10-20 03:31–03:33Z (`tools/madis/access_probe.py`; IPv4 forced; 20 s timeout, ≤2 retries; `logs/access_probe_20261020T0331Z.csv`):

| Time (Z) | URL | Status | Attempts | Note |
|---|---|---|---|---|
| 03:31:41 | `https://madis.ncep.noaa.gov/sample_data/software/sampledata/LDAD/OMO/netCDF/` | 503 | 3 | |
| 03:32:36 | `https://madis.ncep.noaa.gov/madis_OMO.shtml` | 503 | 3 | |
| 03:32:36 | `https://madis.ncep.noaa.gov/sfc_OMO_variable_list.shtml` | 503 | 3 | |
| 03:32:37 | `https://madis-data.ncep.noaa.gov/` | 200 | 1 | distribution home |
| 03:32:37 | `https://madis-data.ncep.noaa.gov/madisPublic1/data/` | 200 | 1 | directory index (path was a guess) |
| 03:32:37 | `https://madis-data.ncep.noaa.gov/madisPublic1/data/LDAD/hfmetar/netCDF/` | **200** | 1 | **directory index, anonymous: the OMO files** (path was a guess) |
| 03:32:37 | `https://madis-data.ncep.noaa.gov/madisResearch/data/` | 403 | 1 | forbidden (path was a guess) |
| 03:32:37 | `https://madis-data.ncep.noaa.gov/madisPublic/cgi-bin/madisXmlPublicDir` | 503 | 3 | Text/XML viewer (path was a guess) |
| 03:32:37 | `ftp://madis-data.ncep.noaa.gov/` | timeout | 1 | anonymous FTP |

- `madis-data` also hangs over IPv6. The first `freshness_poll.py` start (not yet forcing IPv4) logged a listing **read timeout on all 3 attempts at 03:40:45Z**. I deleted that CSV when I restarted the poller, so this sentence is the only record of it. All MADIS scripts now force IPv4.

### api.weather.gov / aviationweather.gov

Both are anonymous over HTTPS with a descriptive User-Agent. *Pending:* the error and availability rates come from the logger.

---

## api.weather.gov: ruled out as primary or fallback (decision 2026-10-20)

Three independent defects, each measured. **Decision (Jeff, 2026-10-20): these rule out api.weather.gov as a primary or fallback 5-minute source.** None of these values were adjusted or filled in.

### A1. Gusts missing: disqualifying as a gust source

- KIGM METAR `192251Z AUTO 25006G16KT` reported a 16 kt gust. The api.weather.gov 5-minute obs on either side have `windGust: null` (QC `Z`): 22:45Z 250°/9 kt, 22:50Z 250°/7 kt, 22:55Z 240°/9 kt (`tools/madis/check_nws_units.py`; raw in `data/nws_KIGM_*.json`, not committed).
- Over 24 h (2026-10-19 03:30Z → 2026-10-20 00:10Z), only **3 of 1,638** off-hour api.weather.gov obs across all 9 stations had any gust value (KEED 1, KSLC 2). In the same 24 h, AWC returned 2 gust METARs out of 294 (KIFP 2149Z `20004G11KT`, KIGM 2251Z above).
- Caveats: one event on a calm day. The 5-minute obs aren't at the METAR's minute, and the 5-minute wind is a 2-minute average. These don't change the conclusion: a METAR gust was reported and the feed had no gust within ±5 min.

### A2. Nationwide stall: HTTP 200 with stale data

- At 2026-10-20 03:26Z, the newest obs for **every** station checked was 00:10Z (KSEA 00:05Z). That includes the 9 spike stations plus KJFK, KORD, KMIA and KSEA. All responses were **HTTP 200**. AWC had current 0251–0253Z METARs for the same stations.
- Before the full stall, there were gaps at every station simultaneously: 18:55→19:40Z and 21:35→22:35Z. METAR-bearing obs (`rawMessage`) stopped after ~17:56Z.
- A client can't detect this from status codes. It has to compare obs age itself.
- Stall duration and recovery time: *pending* (logger running to 06:24Z; see Q3).

### A3. Altimeter missing at KLAS, KHND, KBVU

- `barometricPressure` was null on **every** obs in 24 h at KLAS (238 obs), KHND (238) and KBVU (46). That includes obs whose `rawMessage` carries an `A`-group (e.g. `KLAS 191756Z … A3005`). Other stations populate it.

### A4. Official METARs dropped

- The KIGM 2251Z METAR (the gust report) **never appeared** on api.weather.gov. The feed has a 22:50Z and a 22:55Z 5-minute ob but no 22:51Z METAR record. So the feed drops official METARs too, not just 5-minute obs.

### A5. What did check out (for the record)

- In 114 METAR-bearing api.weather.gov obs, every **present** value matched the METAR text: wind kt (km/h ÷ 1.852), direction, vis SM (m ÷ 1609.344), altimeter (Pa ÷ 3386.389 → A-group), and temp/dewpoint to 0.1 °C (T-group). All 47 mismatches were **missing** values: altimeter null in all 47 (KLAS 10, KHND 10, KBVU 27). One of them (KBVU 1835Z `00000KT`) also has the calm wind stored as null speed/direction.
- When healthy, cadence is 5 minutes at the ASOS sites **and at KHND (AWOS-3PT)**. KBVU (AWOS-3) runs every 20 min and KIFP (AWOS-3PT) every 15–25 min. Both AWOS feeds were ~9 h stale at 03:26Z while AWC had their current METARs.

---

## MADIS OMO via the public hfmetar directory

### H1. What it is

- URL: `https://madis-data.ncep.noaa.gov/madisPublic1/data/LDAD/hfmetar/netCDF/`. Anonymous HTTPS directory index (200), found by `access_probe.py`.
- **Being openly browseable doesn't confirm we're licensed to use it from a paid app's proxy.** The OMO dataset is marked "No restrictions. All observations are publicly accessible" (`madis_OMO.shtml`). However, each file's `license` attribute says "To access MADIS data fill out the application at https://madis.ncep.noaa.gov/data_application.shtml. Some of the MADIS data are restricted." Jeff is confirming with MADIS support.
- Listing at 03:36:20Z: **123 files**, `YYYYMMDD_HHMM.gz`, hourly from `20261015_0100.gz` to `20261020_0300.gz` (a rolling ~5 days). Sizes are 1.1–1.3 MB gzipped (~19 MB unpacked). The current hour was 504K and still growing.
- Listing mtimes are UTC (they match the download's `Last-Modified` GMT header). The current and previous hour are rewritten every few minutes. Each file's last write is at about **HH+2:41**, which fits the doc's "data that arrive after 2 hours … data recovery mode".
- File inspected: `20261019_2200.gz` (final, not the newest).
  - `NETCDF3_CLASSIC`, `title = "MADIS - Meteorological Surface - High frequency METAR"`, `dataProvider`/`stationType = "HF-METAR"`.
  - 12,110 records, 1,023 stations.
- **It is OMO.** The OMO page says these obs were "originally referred to as HF-METAR". Every variable in the OMO variable list has a netCDF counterpart (API mnemonic → netCDF name): FFGUST→`windGust` (m/s, max QC level 1), SKYCOV→`skyCvr` (3 layers × 8 chars), SKYCVLB→`skyCovLayerBase` (m), PRESWEA→`presWx`, VIS→`visibility` (m, max QC level 1), ALTSE→`altimeter` (Pa), DENSALT→`densityAltitude`, RVRVR/RVRID/RVRTYPE/RVRLOC→`runwayVisualRange`/`runwayId`/`runwayVRType`/`runwayVRLocation`, DDSS/FFSS/TSS/TDSS/PSS/SCLBSS/VISSS/PCPTSS/PCPASS/FRZRSS/RVRSS→`windDirStatus`…`runwayVRStatus`, OPSTAT→`siteStatus`, PARACT→`parameterActiveStatus`, ARMKST/AUTORMK/OPERRMK→`autoRemarkStatus`/`autoRemark`/`operatorRemark`, ALERT1/2→`alertData1/2`. Each obs also carries DD/QCA/QCR QC words and the original OMO message (`rawMessage`).
- Not CONUS only: the file includes Alaska and Hawaii stations (e.g. PASH, PHKO), contrary to the dataset page.
- Format: `stationId` is a 4-char ICAO. Times are float seconds since epoch (UTC). Units are SI. Missing values are `_FillValue` 3.4028235e+38 or `missing_value` -9999 (netCDF4 masks both); `-999` in `rawMessage`. `rawMessage` holds the original values in kt / SM / inHg / ft.

### H2. Content and cadence (`omo_dump.py`, files 21Z and 22Z on 2026-10-19)

- KVGT, KLAS, KHND, KIGM, KEED, KPHX and KSLC each have **12 records/hour, one per 5-minute mark**. Median receive lag at MADIS (`receivedTime − observationTime`) is **139 s**.
- **KBVU and KIFP are not in the feed.** AWOS coverage isn't uniform: KHND and KSGU are AWOS-3PT in NASR and *are* present, while KIFP (AWOS-3PT) is not.
- Field fill in the 22Z hour: wind 10–12/12, vis 12/12, sky 12/12, altimeter 12/12 (including KLAS, KHND and KIGM, where api.weather.gov had none or almost none), T/Td 12/12, density altitude 12/12, present weather 0/12 (clear day), RVR at KPHX and KSLC only, gust 0/12 except KEED 1/12.
- **Conversions:** 168 of 168 station records (7 stations × 2 h) match their own raw OMO message on direction, speed, gust, vis, altimeter, T/Td, density altitude and layer-1 base. The raw field positions are inferred from the format, but every value matched independently.
- **vs METAR** (nearest OMO record within ±5 min, 21Z–22Z): wind, vis, altimeter and temperature agree within timing and rounding. OMO temperature is whole °C, while METAR T-groups are 0.1 °C. Two exceptions:
  - the KIGM gust (H3)
  - the KSLC sky condition (H4)

### H3. Gust acceptance (n=1): FAIL

`gust_acceptance.py` over the 21Z and 22Z files and the 24 h of AWC METARs to 03:39Z:
- **FAIL:** KIGM 2251Z `25006G16KT`. The nearest OMO record (22:50Z) is 250°/7 kt with gust `-999` in the raw OMO message (DD `Z`).
- **NOT COVERED:** KIFP 2149Z `20004G11KT` (KIFP isn't in the OMO feed).
- The OMO KIGM records at 22:45/22:50/22:55 are **value-for-value identical** to api.weather.gov's 5-minute obs. That supports the hypothesis that api.weather.gov's 5-minute obs are OMO, and that the missing gust is missing upstream.
- Positive control: OMO does carry gusts when the sensor reports one. KEED 22:40Z `060/09 G14` (DD `C`). No KEED METAR that hour had a gust.
- Caveat: hfmetar files store only the 5-minute marks, so a gust at the minute in between (22:51) isn't visible. n=1, calm day. The scale test is pending.

### H4. KSLC sky condition: OMO flattens layers (recorded; Mike's list)

| Time (Z) | METAR | Nearest OMO |
|---|---|---|
| 2154 / 21:55 | `FEW080 FEW100 BKN120` (ceiling 12,000 BKN) | `OVC110` |
| 2254 / 22:55 | `FEW085 BKN110` (ceiling 11,000 BKN) | `OVC110` |

- Every KSLC OMO record from 21:45 to 22:55 has **one layer, always OVC**, at 11,000–12,000 ft. The METAR's lower FEW layers are missing and BKN becomes OVC. At 2154Z the ceiling is also one 1,000-ft increment lower than the METAR (OMO was OVC120 at 21:50 and OVC110 at 21:55).
- Flight category is unaffected (VFR either way). OMO doesn't always flatten layers: KPHX (two layers), KIGM and KLAS match their METARs.
- **Decision (Jeff, 2026-10-20):** recorded as a systematic sky-condition difference and added to Mike's list. Ceiling/coverage agreement becomes a Phase 2 acceptance check alongside gust.
- Hypothesis under test: OMO is raw sensor output, while METARs at staffed or augmented stations (KSLC) include observer edits, extra FEW layers, coverage changes and layers above the ceilometer's 12,000 ft limit. Prediction: OMO sky agrees with AUTO METARs and diverges from augmented ones. The scale test is pending.

### H5. Parsing rule: the CLR / 12,500 ft sentinel

OMO reports a clear sky as cover `CLR` with layer base **12,500 ft** (3,810 m). It means "no layers detected below 12,000 ft", the ceilometer limit, and is **never a real layer**. A consumer must not show it as a cloud layer or use it as a ceiling or layer height. api.weather.gov passes the same sentinel through (`cloudLayers: [{"amount": "CLR", "base": 3810 m}]`).

### H6. Question for MADIS support

The OMO page says "MADIS started processing and handling all 1 minute observations in November 2017", but the public hfmetar files hold only the **5-minute marks** (12 records per station-hour). **Is a full 1-minute feed, or a lower-latency feed than the hourly files rewritten every ~5 min, available with an account (FTP/LDM/OPeNDAP/Text-XML)?** This matters for gusts (H3): a METAR gust at :51 is invisible in 5-minute snapshots.

---

## Phase 2 acceptance criterion: gust completeness (MADIS OMO, and any future Synoptic eval token)

**Hypothesis:** api.weather.gov's 5-minute obs probably come from the same MADIS 1-minute ASOS (OMO) feed. If so, OMO may also leave gusts out. The OMO variable list shows the gust variable (FFGUST) with QC level 1 only. To be confirmed against the variable list once the page is reachable.

**Pass/fail check:** for every METAR that reports a gust (`G` in the wind group) during the evaluation window, the nearest OMO record (within ±5 min of the METAR time) must carry a non-missing gust.
- **Pass:** every gust METAR has a gust-bearing OMO record nearby.
- **Fail:** any gust METAR with no gust in the nearest OMO record. Report the count and the raw pairs.
- Apply the same check unchanged to Synoptic if an eval token is obtained.
- Needs a window with real gusts. A calm day can't pass it, so the result is "not tested" until enough gust METARs have been seen.

---

## Product requirement, whatever the source (for Mike)

**A 5-minute ob with a missing gust must never display as "no gust" or calm.**

- The app must distinguish **"gust not reported"** from **"no gust"**.
- When the 5-minute data has no gust, the latest METAR's gust stays visible.
- The same rule applies to every field a 5-minute source can drop: altimeter, visibility, ceiling. Unknown must never read as good.

Where the current ASOS UI fails this (read-only, line numbers on `feat/trend-time-spine`):
- `WeatherDetailView.swift:571`: `obs.windGust.map { " gusting …" } ?? ""`. A missing gust renders exactly like no gust.
- `WeatherDetailView.swift:577`, `:582`, `:619`: vis, ceiling and altimeter rows are simply omitted when nil, with no "not reported" marker. The METAR value isn't carried forward.
- `SynopticObservation.estimatedCategory`: missing vis plus confirmed-clear sky gives VFR.
- Alerts: on `feat/trend-time-spine`, `AlertConditions.init(from: SynopticObservation)` leaves nil wind/vis as nil so the criteria are skipped (the F8 fix). On `main` they still fall back to 0 kt / 10 SM (`AlertConditions.swift:69`, `:73`, `:86-87`). A nil gust is indistinguishable from "no gust" on both branches.

This is the same "unknown shown as good" class as audit Findings **6, 7, 8, 12, 13, 15** in `docs/AUDIT_metar_taf_findings.md` (on `feat/trend-time-spine`). Note: the request cited items 9, 10 and 16. In that doc those are the category-color boundary, decoder order dependence and the chip color axis, so I've cited the matching numbers instead. Jeff to confirm.

**Open questions for Mike:**
1. Labeling of 5-minute data ("supplemental, not official").
2. When the 5-minute value and the METAR disagree, which one is shown, and how?
3. How should "not reported" look for gust, altimeter, vis and ceiling?
4. **OMO sky condition can differ from the METAR** (H4). OMO can show a single OVC layer where the METAR shows BKN plus lower FEW layers. At augmented stations the METAR may include observer-added layers. Which one should the app show for sky/ceiling, and how is the difference labeled?

---

## Q7. Terms (evidence gathered so far)

- OMO page (`madis_OMO.shtml`, retrieved 2026-10-20): "Restrictions: **No restrictions.** All observations are publicly accessible." It also says OMO are "binary messages that do not conform to the METAR data standard (FMH1) and should not be considered to be METAR observations." (Page last updated 15 March 2017.)
- `madis_restrictions.shtml` (last updated 24 May 2017): the "notify NOAA before redistributing / web display" rule and the suggested disclaimer apply to **mesonet** providers (Meteorological Surface incl. UrbaNet / National Mesonet), not OMO.
- `madistosynoptic.shtml` (updated 2026-02-11) lists some state-DOT/university **mesonet** providers that moved to Synoptic. It doesn't mention OMO/ASOS.
- So far nothing forbids display in a paid app. Labeling ("not METAR") is still a question for Mike.
