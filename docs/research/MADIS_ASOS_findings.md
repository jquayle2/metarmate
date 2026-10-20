# MADIS / 5-minute ASOS findings

Spike brief: `docs/handoffs/MADIS_spike_handoff.md`. Branch `spike/madis-omo`.
Status: **Phase 1 complete (2026-10-20).** Phase 2 waits on Jeff's MADIS account. The recommendation is at the end.

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

Both are anonymous over HTTPS with a descriptive User-Agent. In the logger run (02:56–06:19Z, 60 s polls, 20 s timeout, ≤2 retries), the error log for both sources is empty: every request got an HTTP response. api.weather.gov's failure was stale data behind HTTP 200 (A2), which the error log can't catch.

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
- **Stall duration and recovery** (`compare_sources.py`, 02:56–06:19Z, both CSVs merged):
  - Every logger start (02:56Z and 03:24Z) saw newest obs 00:10Z at all 9 stations.
  - The first newer obs appeared at **04:19:40Z** (KVGT/KLAS, obs 03:50Z). By **04:24:41Z** all 9 stations were back. So no new data reached a client for **~4 h 10 min** (newest obs 00:10Z → first new obs visible 04:19Z).
  - After recovery the newest obs ran 03:30Z onward. The 00:15–03:25Z obs never showed up in the `limit=5` window. Whether they were backfilled is unknown.
  - Latency after recovery (first seen − obs time, new obs seen within 30 min, n=91): median **1,483 s (~25 min)**, min 882 s, max 1,784 s. That's slow even when healthy.
  - KBVU went stale again after its 03:35Z obs.

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
- Field fill in the 22Z hour: wind 10–12/12, vis 12/12, sky condition 12/12 (real layers, or the CLR sentinel in H5; at KVGT all 12 were the sentinel), altimeter 12/12 (including KLAS, KHND and KIGM, where api.weather.gov had none or almost none), T/Td 12/12, density altitude 12/12, present weather 0/12 (clear day), RVR at KPHX and KSLC only, gust 0/12 except KEED 1/12.
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
- Caveat: hfmetar files store only the 5-minute marks, so a gust at the minute in between (22:51) isn't visible. n=1, calm day. **The scale test (S2) confirms the FAIL across 27,560 paired gust METARs.**

### H4. KSLC sky condition: OMO flattens layers (recorded; Mike's list)

| Time (Z) | METAR | Nearest OMO |
|---|---|---|
| 2154 / 21:55 | `FEW080 FEW100 BKN120` (ceiling 12,000 BKN) | `OVC110` |
| 2254 / 22:55 | `FEW085 BKN110` (ceiling 11,000 BKN) | `OVC110` |

- Every KSLC OMO record from 21:45 to 22:55 has **one layer, always OVC**, at 11,000–12,000 ft. The METAR's lower FEW layers are missing and BKN becomes OVC. At 2154Z the ceiling is also one 1,000-ft increment lower than the METAR (OMO was OVC120 at 21:50 and OVC110 at 21:55).
- Flight category is unaffected (VFR either way). OMO doesn't always flatten layers: KPHX (two layers), KIGM and KLAS match their METARs.
- **Decision (Jeff, 2026-10-20):** recorded as a systematic sky-condition difference and added to Mike's list. Ceiling/coverage agreement becomes a Phase 2 acceptance check alongside gust.
- Hypothesis under test: OMO is raw sensor output, while METARs at staffed or augmented stations (KSLC) include observer edits, extra FEW layers, coverage changes and layers above the ceilometer's 12,000 ft limit. Prediction: OMO sky agrees with AUTO METARs and diverges from augmented ones. **Confirmed for layers, not for category (S1).**

### H5. Parsing rules: sentinels that are never real values

1. **Sky: CLR / 12,500 ft.** OMO reports a clear sky as cover `CLR` with layer base **12,500 ft** (3,810 m). It means "no layers detected below 12,000 ft", the ceilometer limit, and is **never a real layer**. A consumer must not show it as a cloud layer or use it as a ceiling or layer height. `omo_dump.py` implements this: the sentinel is dropped from `sky` and reported as `sky_clear_below_12k: true`. api.weather.gov passes the same sentinel through (`cloudLayers: [{"amount": "CLR", "base": 3810 m}]`).
2. **Gust: 254/255 kt with QC flag `X`.** Some stations report a gust of 254 or 255 kt (`255` in the raw OMO message), with `windGustDD = "X"` (failed QC). Across the 120-file archive this happened in **5,559 records**, mostly from a few stations (KFFT 1,440, KTMB 1,440, KRKD 767, KLGA 312). `X` appears on exactly those values and on no other gust: 0 of 126,874 other gust values carry it. Visibility, wind speed and altimeter had no `X`-flagged values. It means "no valid gust" and **must be read as missing, never as a gust**. Read raw, it shows up as a +230 kt gust. Implemented in `omo_dump.py` (`4f56473`) and `scale_compare.py`.

### H6. Questions for MADIS support

1. The OMO page says "MADIS started processing and handling all 1 minute observations in November 2017", but the public hfmetar files hold only the **5-minute marks** (12 records per station-hour). **Is a full 1-minute feed, or a lower-latency feed than the hourly files rewritten every ~5 min, available with an account (FTP/LDM/OPeNDAP/Text-XML)?**
2. **With an account, is true 1-minute data available, including each minute's peak 5-second gust?** That would let a consumer build a METAR-equivalent 10-minute peak gust, which the 5-minute marks can't (S2).
3. Licensing for display in a paid app behind our proxy (H1).

---

## OMO vs METAR at scale (5-day hfmetar archive)

Tools: `fetch_omo_archive.py`, `fetch_metar_history.py`, `scale_compare.py` (at `fad910b`). Trimmed results: `docs/research/excerpts/scale_results_20261020T1223Z_excerpt.json`. Full JSON and inputs are not committed.

### S0. What was compared

- **OMO archive:** 120 contiguous hourly files, `20261015_1000.gz` to `20261020_0900.gz`, downloaded 2026-10-20 12:16Z. All HTTP 200, 1.13–1.35 MB each, and all decompress cleanly. The archive rolls (the first file was `20261015_0100` at 03:36Z), so the start depends on download time.
- **METAR history:** aviationweather.gov, one request per station for all 1,023 stations in an OMO file, `hours=124`, fetched 03:48–04:20Z. All HTTP 200, none truncated at 400 results, none empty: 153,570 METARs.
- **Overlap actually analysed:** **2026-10-15 10:00Z → 2026-10-20 04:18Z, 114.3 h.**
  - 140,073 METARs from 1,023 stations.
  - Station-hours with a METAR: **75,243 AUTO, 40,382 augmented.**
  - METARs with a gust: **17,589 AUTO, 10,040 augmented.**
- **Pairing:** each METAR to the nearest OMO record for the same station within ±5 min. "AUTO" means the METAR text has the AUTO modifier. "Augmented" means it doesn't (observer involved).
- **Sky test sample:** 50 always-AUTO stations and 50 never-AUTO stations, CONUS `K` identifiers only, seed 20261020. In the overlap, 459 stations were always AUTO, 98 never AUTO and 356 mixed.
- **Rules applied:**
  - CLR/12,500 ft is "nothing below 12,000 ft" (H5.1).
  - A 254/255 kt `X` gust is missing (H5.2).
  - OMO records with no sky group at all are excluded, not read as clear: 125 AUTO, 393 augmented.

### S1. Sky / ceiling / flight category: PASS (with caveats)

| Agreement (METAR vs nearest OMO) | AUTO (50 stations) | Augmented (50 stations) |
|---|---|---|
| Flight category (FAA: LIFR/IFR/MVFR/VFR) | **98.1%** (6,166 / 6,286) | **98.0%** (5,563 / 5,677) |
| Ceiling (both none, or within 100 ft below 5,000 / 500 ft at or above) | 96.4% (6,198 / 6,430) | 88.3% (5,106 / 5,784) |
| Ceiling, both sides limited to layers ≤ 12,000 ft | 96.4% | **95.1%** |
| Ceiling, only pairs where either side has one | 88.0% (1,702 / 1,934) | 69.0% (1,510 / 2,188) |
| Layer count / cover sequence | 97.1% / 93.8% | **67.1% / 63.6%** |
| Layer count / cover sequence, ≤ 12,000 ft | 97.1% / 93.8% | 86.0% / 81.8% |

- **Hypothesis confirmed for layers.** At AUTO stations the METAR's layers essentially *are* the sensor's. At augmented stations, layers diverge. Most of the difference sits above 12,000 ft: observer-added high layers beyond the classic ceilometer range, with nothing in OMO up there. The rest is observer edits below 12,000 ft (coverage changes, added FEW layers, as at KSLC in H4).
- **The 12,000 ft limit is a caveat, not a rule.** Some ASOS ceilometers report higher. KADF shows 19,000–22,000 ft layers in OMO and its AUTO METAR alike. OMO saying "nothing below 12,000 ft" is not "clear".
- **Flight category agrees equally in both groups (98%).** The remaining ceiling disagreements are mostly one ceilometer increment or a timing shift (the OMO record is 1–2 min off the METAR). Many fall right after a SPECI.
- **Direction of the category misses:** AUTO 64 OMO-better / 56 OMO-worse; augmented 64 / 50. Misses of two or more categories: AUTO 11, augmented 16.
- **METAR IFR/LIFR but OMO VFR (the dangerous direction): 12 pairs.** 11 are SPECIs, issued while conditions were changing fast, with an OMO record 1–3 min away. **The one routine METAR is KMCI:**
  - METAR `KMCI 151453Z 13003KT 5SM -RA BR BKN003 BKN010 OVC130` → LIFR (BKN003 ceiling).
  - The OMO record 2 min later has 6 SM, `FEW003 BKN034 OVC045` → VFR.
  - Same layer height, different amount. The observer's BKN003 makes a 300 ft ceiling; the sensor's FEW003 makes no ceiling below 3,400 ft. A display that trusted OMO here would show VFR under a LIFR METAR. That's the case the product rule below exists to prevent.

### S2. Gust: FAIL as a gust authority (hfmetar 5-minute data)

| Gust METARs (wind group with `G`) | AUTO | Augmented |
|---|---|---|
| In overlap / paired with OMO (±5 min) | 17,589 / 17,559 | 10,040 / 10,001 |
| **Nearest OMO record carries a gust** | **39.5%** (6,944) | **42.1%** (4,213) |
| Any OMO record from 10 min before to 5 min after carries a gust | 68.3% (11,986) | 73.8% (7,383) |
| Delta OMO − METAR, nearest record: median / mean / within ±2 kt | −3 / −3.07 / 46.8% | −3 / −3.07 / 44.9% |
| Delta, largest OMO gust in that window: median / mean / within ±2 kt | −1 / −1.91 / 63.5% | −1 / −1.91 / 63.0% |
| Delta range (largest in window) | −28 … +12 kt | −16 … +14 kt |

- **Result: FAIL** under the Phase 2 criterion below, which requires every gust METAR to have a gust-bearing OMO record nearby. Most nearest records have no gust. When OMO has a gust it is typically **lower** than the METAR's.
- **Sampling caveat, measured:** a METAR gust is the peak over the last 10 min, while the hfmetar files keep only the 5-minute marks. Taking the largest gust from every 5-minute mark in the 10-minute window raises coverage to ~70% and cuts the bias to −1 kt. That still leaves **~30% of METAR gusts with no OMO gust at all** and a low bias. Sampling explains part of the gap, not all of it.
- AUTO and augmented behave the same. The gust comes from the sensor at both, so this is a 5-minute-product issue, not an observer issue.
- **Hypothesis (untested): Synoptic's HF-ASOS has the same gap.** Per the handoff, Synoptic gets this data from NOAA MADIS. Its HF-ASOS page describes the same product (2-minute average wind, lower precision, ASOS only). If it shares the upstream, it inherits the same gust gap. **Testable only with a Synoptic eval token**, by running the same criterion (`scale_compare.py`'s gust block) on Synoptic data for the same window.
- Gust from OMO is therefore usable to **warn** (a gust appeared), never to **confirm** there's no gust, and never to lower a METAR gust.

---

## Q3. Freshness

### hfmetar (`freshness_poll.py`, 2026-10-20 03:41–04:41Z, 28 listing polls at 120 s)

- **Path to us:**
  1. Sensor obs at a 5-minute mark.
  2. MADIS receives it about **2.3 min** later. In each current-hour download, newest `receivedTime` minus newest `observationTime` was 135–140 s (median per-record lag 139 s in H2).
  3. It lands in the current-hour file **7.2–11.8 min** after the obs (file `Last-Modified` minus newest obs, 6 file versions).
  4. We see it **12.0–18.0 min** after the obs (our fetch minus newest obs, measured when a changed file was downloaded: 718, 739, 760, 760, 800 and 1,079 s).
- **Floor:** with a 2-minute poll, the newest 5-minute value is about **12 min old** when we first have it. Best case for a proxy polling the current-hour file is ~10 min.
- The hour file rolls at HH:00. The :55 record lands in the *previous* hour's file, which keeps being rewritten until ~HH+2:41. A proxy has to read both files.
- **CDN inconsistency:**
  - The listing sometimes advertised a newer mtime than the file served (e.g. listing 04:16, served `Last-Modified` 04:11:15).
  - Once the listing went *backwards*: 04:21/273K at 04:22:59Z, then 04:16/120K at 04:24:59Z. Edge nodes disagree.
  - A proxy must key on the newest `observationTime` inside the file, not on the listing or headers.
- **Availability:** 7 of 28 polls hit a 20 s read timeout (×3 attempts) on the listing or a download, even over IPv4. That's about 1 in 4 polls, so the proxy needs retries, a stale-data check and a fallback to METAR.

### Logger (`compare_sources.py`, 02:56–06:19Z, 60 s polls; rows with `initial=1` excluded)

| Source | New obs | First seen − obs time: median (min–max) | Note |
|---|---|---|---|
| aviationweather.gov METAR | 41 | **281 s** (147–641) | AWC `receiptTime − obs` median 200 s |
| api.weather.gov | 185 (91 seen within 30 min) | **1,483 s** (882–1,784) after recovery | 4 h 10 min stall, see A2 |

---

## App finding: where 5-minute gust and wind feed decisions (read-only, no fixes)

Under-reported gusts (S2) make conditions look **better** than they are. This is the same P1 "unknown or understated shown as good" class as the audit items 4–16 Jeff cited (`docs/AUDIT_metar_taf_findings.md` on `feat/trend-time-spine`).

Exposure: all of this sits behind `isAsosUser`. On build 21 that is off (`FeatureFlags.asosAvailable = false`, P0-4). On `main` / ≤20 it is live for subscribers and during the free window.

Line numbers: `main` / build 21 (`feat/trend-time-spine`).

| # | Site | What the 5-minute gust/wind drives | Failure with an under-reported or missing gust |
|---|---|---|---|
| 1 | `AlertPipeline.swift:121-122` / `:128-129` | Alerts use the live ASOS ob **instead of** the METAR whenever the Synoptic fetch succeeds | The METAR gust is dropped entirely for that station |
| 2 | `AlertConditions.swift:70` / `:71` | `windGust: obs.windGust.map { … }`: nil means "no gust" | Missing is indistinguishable from none |
| 3 | `GoNoGoEvaluator.swift:70-74` / same | Crosswind factor via `RunwayService.bestRunway(… windGust:)`. `RunwayService.swift:97` uses gust when present, else sustained | XW computed on sustained (or a low gust) can pass the crosswind limit |
| 4 | `GoNoGoEvaluator.swift:97-98` / `:97` | Gust factor: `windGust ?? windSpeed` | Gust limit tested against sustained wind |
| 5 | `AlertPipeline.swift:150` / `:157` | Notification body "Back within your minimums" on a NO-GO → GO flip | **The reassuring direction:** a 5-minute ob with no gust can flip a gusty METAR's NO-GO to GO and notify |
| 6 | `AlertsView.swift:325`, `:355` (`main`) | Alert row wind color and `dddGg` text from `AlertConditions` | Shows no gust, color from sustained only |
| 7 | `WeatherDetailView.swift:550-552` / `:571-572` | Decoded ASOS wind row: `obs.windGust.map { " gusting …" } ?? ""` | A missing gust renders exactly like no gust |
| 8 | `WeatherDetailView.swift:719-724` / `:743` | `windConditionColor`: green unless gust, ≥20 kt or 10 kt spread | Missing gust under 20 kt shows **green** |
| 9 | `WeatherDetailView.swift:329-332`, `:364-366` / `:348-351`, `:383-385` | Wind strip, last 12 obs: bar scale `max(gust ?? speed)`, gust bar only when present | Gusty hour looks steady |
| 10 | `WeatherDetailView.swift:484-492` / `:505-513` | "Gusts developed: N kt" (METAR had no gust) and "Gusts ±N kt" vs METAR | Warns only if OMO happens to carry a gust. With the −3 kt bias, prints **"Gusts −5 kt"**, which reads as easing |
| 11 | `WeatherDetailView.swift:475-481` / `:496-502` | "Wind ±N kt" vs METAR | A lower 2-min average prints "Wind −5 kt" (reassuring) |
| 12 | `WeatherDetailView.swift:495-502` / `:516-523` | "Wind shifted N°" | Direction only; not gust-related, listed for completeness |
| 13 | `WeatherDetailView.swift:285-307` / `:304-` | `openXWCalc` passes ASOS dir/speed/gust (`&gust=0` when nil) to the external XW app | **No call site on either branch** (dead code). If wired up, a missing gust becomes `gust=0` |

Not ASOS-fed: the detail view's crosswind range and pilot notes (`crosswindDisplays`, `WeatherDetailView.swift:875` on `main`) are called from the METAR and TAF note builders only.

---

## Phase 2 acceptance criterion: gust completeness (MADIS OMO, and any future Synoptic eval token)

**Hypothesis:** api.weather.gov's 5-minute obs probably come from the same MADIS 1-minute ASOS (OMO) feed. If so, OMO may also leave gusts out. The OMO variable list shows the gust variable (FFGUST) with QC level 1 only. To be confirmed against the variable list once the page is reachable.

**Pass/fail check:** for every METAR that reports a gust (`G` in the wind group) during the evaluation window, the nearest OMO record (within ±5 min of the METAR time) must carry a non-missing gust.
- **Pass:** every gust METAR has a gust-bearing OMO record nearby.
- **Fail:** any gust METAR with no gust in the nearest OMO record. Report the count and the raw pairs.
- Apply the same check unchanged to Synoptic if an eval token is obtained.
- Needs a window with real gusts. A calm day can't pass it, so the result is "not tested" until enough gust METARs have been seen.

**Result on the public hfmetar archive: FAIL** (S2). 27,560 gust METARs were paired. The nearest OMO record carried a gust for 40%, and any record in a 15-minute window for ~70%. Phase 2 reruns the check on account-based data, in case a 1-minute feed exists (H6.2).

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

**Proposed product rule (for Mike to rule on): 5-minute data may warn but never reassure.**

1. A 5-minute value **worse** than the current METAR is shown, labeled as 5-minute ASOS. Worse means higher wind or gust, lower vis or ceiling, or a worse category.
2. A 5-minute value **better** than the METAR never changes the displayed flight category, go/no-go verdict, alert state or gust. It can appear as a labeled trend, at most. The METAR value stays authoritative until the next METAR/SPECI.
3. **Displayed gust = max(latest METAR gust while that METAR is current, any 5-minute gust in the last 10 min), labeled by source.** A missing 5-minute gust never lowers or clears it.
4. Missing is never good (the requirement above).

This rule covers the measured cases: the KMCI LIFR→VFR pair (S1), the −3 kt gust bias and the missing gusts (S2), and app sites 1–11 in the app finding.

**Open questions for Mike:**
1. Labeling of 5-minute data ("supplemental, not official").
2. When the 5-minute value and the METAR disagree, which one is shown, and how?
3. How should "not reported" look for gust, altimeter, vis and ceiling?
4. **OMO sky condition can differ from the METAR** (H4). OMO can show a single OVC layer where the METAR shows BKN plus lower FEW layers. At augmented stations the METAR may include observer-added layers. Which one should the app show for sky/ceiling, and how is the difference labeled? Scale result (S1): category agrees 98% either way, and layers agree 94% at AUTO stations but 64% at augmented ones.
5. **Approve or amend the warn-never-reassure rule above**, including the displayed-gust formula and the 10-minute window.
6. Should 5-minute "worse" signals ever drive alerts/notifications (warn-only), or stay display-only?

---

## Q7. Terms (evidence gathered so far)

- OMO page (`madis_OMO.shtml`, retrieved 2026-10-20): "Restrictions: **No restrictions.** All observations are publicly accessible." It also says OMO are "binary messages that do not conform to the METAR data standard (FMH1) and should not be considered to be METAR observations." (Page last updated 15 March 2017.)
- `madis_restrictions.shtml` (last updated 24 May 2017): the "notify NOAA before redistributing / web display" rule and the suggested disclaimer apply to **mesonet** providers (Meteorological Surface incl. UrbaNet / National Mesonet), not OMO.
- `madistosynoptic.shtml` (updated 2026-02-11) lists some state-DOT/university **mesonet** providers that moved to Synoptic. It doesn't mention OMO/ASOS.
- So far nothing forbids display in a paid app. Labeling ("not METAR") is still a question for Mike.

---

## Q1–Q7 at a glance (Phase 1)

| Q | Answer so far | Where |
|---|---|---|
| Q1 Access | hfmetar OMO is anonymous over HTTPS (IPv4 only; ~1 in 4 polls time out). The documented sample dir is 403/503. Text/XML returned 503 at a guessed path, so it's **untested**. FTP timed out. | Q1 |
| Q2 Content | Every field the app uses from Synoptic is present (wind, gust, vis, sky ≤3 layers, wx, altimeter, T/Td) plus density altitude, RVR and sensor status. Two sentinels to parse (H5). | H1, H2, H5 |
| Q3 Freshness | hfmetar: 12–18 min from obs to us (floor ~10–12). AWC METAR: ~4.7 min. api.weather.gov: ~25 min when healthy, plus a 4 h stall. | Q3 |
| Q4 Coverage (100 nm of KVGT) | OMO: KVGT, KLAS, KHND (AWOS-3PT), KIGM, KEED. Not KBVU (AWOS-3), not KIFP (AWOS-3PT). | H2 |
| Q5 Agreement | Wind, vis, altimeter, T match METAR within rounding/timing. Category 98%. Layers diverge at augmented stations. **Gust fails.** | H2, S1, S2 |
| Q6 Ops | hfmetar: ~1.1–1.35 MB/h per gz file, ~12,000 records, ~1,030 stations. A proxy polling the current and previous hour every 5 min pulls at most ~29 MB/h (~21 GB/month). The parse and record extraction in `omo_dump.py` is 162 lines of Python, including the CLI. Hosting cost not estimated. Q6 for api.weather.gov/AWC was skipped per Jeff. | H1, Q3 |
| Q7 Terms | OMO is marked "No restrictions". The file `license` attribute points to the account application. Paid-app proxy display is unconfirmed until MADIS support replies. | H1, Q7 |

---

## Decision matrix

Scores are 1 (poor) to 5 (good), from this spike's measurements. "—" means not measurable in Phase 1.

| Criterion | Synoptic (paid) | MADIS hfmetar netCDF ingest | MADIS Text/XML | api.weather.gov |
|---|---|---|---|---|
| Freshness | — (docs: 2–5 min; no token) | 3 (12–18 min to us; ~10 min floor) | — (503, untested) | 1 (~25 min healthy; 4 h stall) |
| Coverage | — (docs: ASOS only) | 4 (ASOS + some AWOS-3PT; ~1,030 stations) | — | 3 (5 min at ASOS; AWOS stale) |
| Completeness | — (likely same gust gap; hypothesis) | 3 (all fields; gust fails S2) | — | 1 (gusts, altimeter missing; METARs dropped) |
| Reliability | — (account expired) | 3 (~25% poll timeouts, CDN inconsistency; retries manage) | 1 (503) | 1 (silent HTTP 200 stall) |
| Effort | 5 (existing code) | 3 (netCDF ingest + sentinels in a proxy) | — | 4 (JSON) |
| Cost | 2 ($100/month) | 5 (free; license to confirm) | 5 (free) | 5 (free) |

---

## Recommendation (Phase 1)

**MADIS hfmetar (OMO), ingested by the proxy from the current and previous hourly netCDF files, is viable as the ASOS Updates source** for:
- wind direction and speed
- visibility
- ceiling and flight-category trend
- altimeter
- temperature and dewpoint

All of these are subject to the **warn-never-reassure rule** (Product requirement), with **gust taken from the METAR**. A 5-minute gust may raise the displayed gust and never lower or clear it.

- **Primary:** MADIS hfmetar via the proxy. Parse both sentinels (H5). Key freshness on the in-file `observationTime`. Force IPv4, use short timeouts and retries, and treat any value older than ~20 min as stale.
- **Fallback:** the official METAR from aviationweather.gov, which the app already uses. No second 5-minute source is needed: api.weather.gov is ruled out, and Text/XML is untested.
- **Synoptic is not justified at this point.** It would cost $100/month for the same upstream (per the handoff). The measured gust gap is in the 5-minute product, and Synoptic probably shares it (S2 hypothesis, testable only with an eval token). Freshness is its one documented advantage (2–5 min vs our measured 12–18 min), and that is worth revisiting only if MADIS support offers no faster or 1-minute feed (H6).

**Conditions before building:**
1. MADIS support confirms licensing for paid-app display via our proxy (H6.3).
2. Mike rules on the product rule and open questions 1–6.
3. Phase 2 (account) reruns gust and freshness against any account feed (H6.1–2).
4. The app sites in the app finding are fixed to the approved rule before ASOS Updates is re-enabled. `FeatureFlags.asosAvailable` keeps it off until then.
