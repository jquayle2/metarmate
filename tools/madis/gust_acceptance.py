"""Gust-completeness acceptance test (findings doc, Phase 2 criterion).

For every METAR in the window that reports a gust (G in the wind group), find the
nearest-in-time OMO record for that station within +/- --window-min in the given
hfmetar files and report whether it carries a gust.

  PASS         nearest OMO record has a gust
  FAIL         nearest OMO record exists but its gust is missing
  NOT COVERED  station has no OMO record within the window (e.g. AWOS not in the feed,
               or the hour's file wasn't supplied)

METARs come from aviationweather.gov (one request). Values are reported, not adjusted.

Usage: gust_acceptance.py FILE.gz [FILE.gz ...] [--hours 24] [--window-min 5]
"""
import argparse
import re
from datetime import datetime, timedelta, timezone

from common import ICAOS, get
from omo_dump import open_dataset, records

WIND = re.compile(r"\b(\d{3}|VRB)(\d{2,3})G(\d{2,3})KT\b")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--hours", type=int, default=24)
    ap.add_argument("--window-min", type=int, default=5)
    args = ap.parse_args()

    omo = {}
    for path in args.files:
        ds = open_dataset(path)
        for rec in records(ds, ICAOS):
            t = datetime.fromisoformat(rec["obs_time"].replace("Z", "+00:00"))
            omo.setdefault(rec["icao"], {})[t] = rec
        ds.close()

    r, *_ = get("https://aviationweather.gov/api/data/metar",
                params={"ids": ",".join(ICAOS), "format": "json", "hours": args.hours})
    r.raise_for_status()
    gust_metars = [m for m in r.json() if WIND.search(m.get("rawOb", ""))]
    print(f"{len(gust_metars)} gust METARs of {len(r.json())} in the last {args.hours} h\n")

    tally = {"PASS": 0, "FAIL": 0, "NOT COVERED": 0}
    for m in sorted(gust_metars, key=lambda m: m["obsTime"]):
        t = datetime.fromtimestamp(m["obsTime"], timezone.utc)
        w = WIND.search(m["rawOb"])
        recs = omo.get(m["icaoId"], {})
        near = [(abs((ot - t).total_seconds()), ot) for ot in recs
                if abs(ot - t) <= timedelta(minutes=args.window_min)]
        if not near:
            verdict, detail = "NOT COVERED", f"no OMO record within ±{args.window_min} min"
        else:
            rec = recs[min(near)[1]]
            verdict = "PASS" if rec["wgst_kt"] is not None else "FAIL"
            detail = (f"nearest OMO {rec['obs_time']}: {rec['wdir']}/{rec['wspd_kt']} kt "
                      f"gust={rec['wgst_kt']} (DD={rec['qc']['windGustDD']}) raw={rec['raw'][:90]}")
        tally[verdict] += 1
        print(f"{verdict:11} {m['icaoId']} {t:%m-%dT%H:%MZ} METAR {w.group(0)}  |  {detail}")
        print(f"            {m['rawOb']}")
    print(f"\n{tally}")
    print("Overall:", "FAIL" if tally["FAIL"] else ("PASS" if tally["PASS"] else "NOT TESTED"))


if __name__ == "__main__":
    main()
