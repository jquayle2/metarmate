"""Download the public hfmetar (OMO) archive, one file at a time.

Fetches the directory listing once, then downloads every *final* hourly file (file hour
at least --final-hours old; files get their last write at about HH+2:41) that isn't
already in data/hfmetar/archive/. Requests go through common.get (20 s timeout, at most
2 retries) with --pause seconds between downloads. IPv4 is forced (the MADIS hosts stall
over IPv6).

Writes logs/omo_archive_<UTC>.csv (file, http, bytes, elapsed_s, error).
"""
import argparse
import csv
import os
import re
import socket
import time
from datetime import datetime, timedelta, timezone

import urllib3.util.connection

from common import get

urllib3.util.connection.allowed_gai_family = lambda: socket.AF_INET

BASE = "https://madis-data.ncep.noaa.gov/madisPublic1/data/LDAD/hfmetar/netCDF/"
NAME = re.compile(r'href="(\d{8}_\d{4}\.gz)"')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pause", type=float, default=2.0)
    ap.add_argument("--final-hours", type=float, default=3.0)
    args = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    outdir = os.path.join(here, "data", "hfmetar", "archive")
    os.makedirs(outdir, exist_ok=True)

    r, *_ = get(BASE)
    r.raise_for_status()
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=args.final_hours)
    names = sorted(set(NAME.findall(r.text)))
    final = [n for n in names
             if datetime.strptime(n[:13], "%Y%m%d_%H%M").replace(tzinfo=timezone.utc) <= cutoff]
    todo = [n for n in final if not os.path.exists(os.path.join(outdir, n))]
    log = os.path.join(here, "logs", f"omo_archive_{now:%Y%m%dT%H%MZ}.csv")
    print(f"{len(names)} listed, {len(final)} final, {len(todo)} to download; log {log}", flush=True)

    with open(log, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["file", "http", "bytes", "elapsed_s", "error"])
        for n in todo:
            try:
                resp, _, elapsed, _ = get(BASE + n)
                if resp.status_code == 200:
                    tmp = os.path.join(outdir, n + ".part")
                    with open(tmp, "wb") as out:
                        out.write(resp.content)
                    os.replace(tmp, os.path.join(outdir, n))
                w.writerow([n, resp.status_code, len(resp.content), round(elapsed, 2), ""])
            except Exception as e:
                w.writerow([n, "ERR", 0, "", repr(e)[:200]])
            fh.flush()
            time.sleep(args.pause)
    print("done", flush=True)


if __name__ == "__main__":
    main()
