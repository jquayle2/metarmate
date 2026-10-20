"""Fetch METAR history from aviationweather.gov for every station in an OMO file.

AWC caps a request at 400 results, so this asks for one station per request and paces
requests (default 1.2 s apart, ~50/min; AWC's documented limit is 100/min). A response of
exactly 400 is flagged as possibly truncated. Existing files are skipped, so it can resume.

Writes data/metars/<ICAO>.json (list of AWC METAR JSON objects) and
logs/metar_history_<UTC>.csv (station, http, count, truncated, error).

Usage: fetch_metar_history.py OMO_FILE.gz [--hours 124] [--pause 1.2]
"""
import argparse
import csv
import json
import os
import time
from datetime import datetime, timezone

import netCDF4 as nc
import numpy as np

from common import get
from omo_dump import open_dataset

URL = "https://aviationweather.gov/api/data/metar"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("omo_file")
    ap.add_argument("--hours", type=int, default=124)
    ap.add_argument("--pause", type=float, default=1.2)
    args = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    outdir = os.path.join(here, "data", "metars")
    os.makedirs(outdir, exist_ok=True)

    ds = open_dataset(args.omo_file)
    stations = sorted(set(str(s) for s in nc.chartostring(ds["stationId"][:])))
    ds.close()
    start = datetime.now(timezone.utc)
    log = os.path.join(here, "logs", f"metar_history_{start:%Y%m%dT%H%MZ}.csv")
    print(f"{len(stations)} stations, hours={args.hours}, log {log}", flush=True)

    with open(log, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["station", "http", "count", "truncated", "error"])
        for i, icao in enumerate(stations):
            dest = os.path.join(outdir, f"{icao}.json")
            if os.path.exists(dest):
                continue
            try:
                r, *_ = get(URL, params={"ids": icao, "format": "json", "hours": args.hours})
                data = r.json() if r.status_code == 200 and r.content else []
                with open(dest, "w") as out:
                    json.dump(data, out)
                w.writerow([icao, r.status_code, len(data), int(len(data) >= 400), ""])
            except Exception as e:
                w.writerow([icao, "ERR", 0, 0, repr(e)[:200]])
            fh.flush()
            if i % 100 == 0:
                print(f"{i}/{len(stations)} {icao}", flush=True)
            time.sleep(args.pause)
    print("done", flush=True)


if __name__ == "__main__":
    main()
