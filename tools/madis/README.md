# MADIS / 5-minute ASOS research spike

Throwaway research tooling for `docs/research/MADIS_ASOS_findings.md`.
Brief: `docs/handoffs/MADIS_spike_handoff.md`. Nothing here ships in the app.

## Setup

Run from the repo root:

```
python3 -m venv tools/madis/.venv && tools/madis/.venv/bin/pip install -r tools/madis/requirements.txt
```

`data/` (downloads) and `logs/` (CSVs) are gitignored. Small committed samples live in `excerpts/`.

## Stations

Defined in `common.py`. ASOS/AWOS type comes from FAA NASR `AWOS.csv` (effective 2026-06-11).
KPHX and KSLC are out-of-radius references.

## Network rules

Every call goes through `common.get`: 20 s timeout, at most 2 retries (connection errors,
timeouts, 5xx). Descriptive User-Agent on every request.

## Scripts

All commands run from the repo root.

**nws_cadence.py**: last N hours of api.weather.gov observations per station; interval
distribution, newest-obs age, field fill on METAR vs off-hour obs. Raw JSON in `data/`,
summary in `logs/nws_cadence_<UTC>.json`.

```
tools/madis/.venv/bin/python tools/madis/nws_cadence.py --hours 6
```

**check_nws_units.py**: checks api.weather.gov conversions against the METAR text on every
METAR-bearing obs from the latest `nws_cadence.py` pull, and lists 24 h of AWC gust METARs.
Prints mismatches. Run `nws_cadence.py` first.

```
tools/madis/.venv/bin/python tools/madis/check_nws_units.py
```

**access_probe.py**: one anonymous pass over a fixed list of MADIS URLs plus anonymous FTP.
Records timestamp, status, bytes and attempts in `logs/access_probe_<UTC>.csv`. Forces IPv4.

```
tools/madis/.venv/bin/python tools/madis/access_probe.py
```

**omo_dump.py**: MADIS 1-minute ASOS (OMO, "HF-METAR") hourly netCDF to per-station JSON
(`data/omo_dump.json`): converted units, QC (DD) flags, sensor status, raw OMO message. Prints
per-station cadence and field fill. Files come from the public, anonymously browseable
`https://madis-data.ncep.noaa.gov/madisPublic1/data/LDAD/hfmetar/netCDF/` (`YYYYMMDD_HHMM.gz`).
Download one at a time with a timeout, for example:

```
curl -4 --max-time 20 --retry 2 -A "MetarMate-research (jquayle2 on GitHub)" -o tools/madis/data/hfmetar/20261019_2200.gz https://madis-data.ncep.noaa.gov/madisPublic1/data/LDAD/hfmetar/netCDF/20261019_2200.gz
```

```
tools/madis/.venv/bin/python tools/madis/omo_dump.py tools/madis/data/hfmetar/20261019_2200.gz
```

**gust_acceptance.py**: gust-completeness acceptance test. For each gust METAR in the last
N hours, checks the nearest OMO record (±5 min) in the given files for a gust. Reports
PASS / FAIL / NOT COVERED. Supply the hourly files that cover the gust METARs.

```
tools/madis/.venv/bin/python tools/madis/gust_acceptance.py tools/madis/data/hfmetar/20261019_2100.gz tools/madis/data/hfmetar/20261019_2200.gz
```

**compare_sources.py**: live logger, api.weather.gov vs aviationweather.gov METAR, one CSV row
per newly seen observation (`logs/compare_<UTC>.csv`, errors in `..._errors.csv`).

```
cd tools/madis && nohup caffeinate -i .venv/bin/python compare_sources.py --hours 3 > logs/compare_run.out 2>&1 &
```

Stop it early:

```
pkill -f compare_sources.py
```

`--interval` (default 60 s) and `--hours` (default 0 = until killed). Rows with `initial=1` were
already present on the first poll; leave them out of latency stats.
