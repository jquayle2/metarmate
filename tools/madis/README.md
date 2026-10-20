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
