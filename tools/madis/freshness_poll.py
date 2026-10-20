"""Phase 1 step 4: hfmetar directory freshness.

Every --interval seconds, fetch the directory listing (one small request). When the
current-hour or previous-hour file's mtime/size changes, download that file (one at a
time) and record the newest observationTime and receivedTime in it, overall and for
KVGT, against our fetch time. The Last-Modified header of each download is logged to
confirm the listing's clock.

Writes logs/freshness_<UTC>.csv. Downloads go to data/hfmetar/fresh/ (overwritten).
"""
import argparse
import csv
import os
import re
import time
from datetime import datetime, timezone

import socket

import numpy as np
import netCDF4 as nc
import urllib3.util.connection

from common import get, iso
from omo_dump import open_dataset

# MADIS hosts complete TLS over IPv6 and then stall (findings Q1); force IPv4.
urllib3.util.connection.allowed_gai_family = lambda: socket.AF_INET

BASE = "https://madis-data.ncep.noaa.gov/madisPublic1/data/LDAD/hfmetar/netCDF/"
ROW = re.compile(r"(\d{8}_\d{4}\.gz)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s+(\S+)")
FIELDS = ["poll_time", "file", "listing_mtime", "listing_size", "changed", "last_modified_hdr",
          "bytes", "records", "newest_obs", "newest_received", "lag_newest_obs_s",
          "kvgt_newest_obs", "kvgt_lag_s"]


def listing():
    r, *_ = get(BASE)
    r.raise_for_status()
    text = re.sub(r"<[^>]+>", "", r.text).replace("&nbsp;", " ")
    return {name: (mtime, size) for name, mtime, size in ROW.findall(text)}


def inspect(path, fetched):
    ds = open_dataset(path)
    obs = np.ma.compressed(ds["observationTime"][:])
    rcv = np.ma.compressed(ds["receivedTime"][:])
    sid = nc.chartostring(ds["stationId"][:])
    kv = np.ma.compressed(ds["observationTime"][:][sid == "KVGT"])
    ds.close()
    to_dt = lambda s: datetime.fromtimestamp(float(s), timezone.utc)
    out = {"records": len(obs), "newest_obs": iso(to_dt(obs.max())),
           "newest_received": iso(to_dt(rcv.max())),
           "lag_newest_obs_s": round((fetched - to_dt(obs.max())).total_seconds())}
    if len(kv):
        out["kvgt_newest_obs"] = iso(to_dt(kv.max()))
        out["kvgt_lag_s"] = round((fetched - to_dt(kv.max())).total_seconds())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=int, default=120)
    ap.add_argument("--minutes", type=float, default=60)
    args = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    fresh = os.path.join(here, "data", "hfmetar", "fresh")
    os.makedirs(fresh, exist_ok=True)
    start = datetime.now(timezone.utc)
    path = os.path.join(here, "logs", f"freshness_{start:%Y%m%dT%H%MZ}.csv")
    seen = {}
    deadline = time.time() + args.minutes * 60
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, FIELDS)
        w.writeheader()
        print(f"logging to {path}", flush=True)
        while time.time() < deadline:
            t0 = time.time()
            now = datetime.now(timezone.utc)
            try:
                files = listing()
            except Exception as e:
                w.writerow({"poll_time": iso(now), "file": "LISTING", "changed": f"ERR {e!r}"[:200]})
                fh.flush()
                time.sleep(args.interval)
                continue
            for name in sorted(files)[-2:]:  # previous and current hour
                mtime, size = files[name]
                row = {"poll_time": iso(now), "file": name, "listing_mtime": mtime,
                       "listing_size": size, "changed": int(seen.get(name) != (mtime, size))}
                if row["changed"]:
                    seen[name] = (mtime, size)
                    try:
                        r, fetched, _, _ = get(BASE + name)
                        r.raise_for_status()
                        dest = os.path.join(fresh, name)
                        with open(dest, "wb") as out:
                            out.write(r.content)
                        row.update({"last_modified_hdr": r.headers.get("Last-Modified", ""),
                                    "bytes": len(r.content)})
                        row.update(inspect(dest, fetched))
                    except Exception as e:
                        row["changed"] = f"ERR {e!r}"[:200]
                w.writerow(row)
                fh.flush()
            time.sleep(max(0, args.interval - (time.time() - t0)))


if __name__ == "__main__":
    main()
