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

## Scripts

Run commands are added as each script lands.
