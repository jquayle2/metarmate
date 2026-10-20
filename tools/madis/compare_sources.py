"""Live side-by-side logger: api.weather.gov observations vs aviationweather.gov METAR.

Polls both sources every --interval seconds and appends one CSV row the first time each
(source, station, obs_time) is seen. latency_s = first_seen - obs_time, so it is an upper
bound with resolution of one poll interval. Rows seen on the first poll are marked
initial=1 (their first_seen is just "when the logger started") and must be excluded from
latency stats.

Native-unit columns are kept next to converted ones so every conversion can be checked
against the raw METAR text. Synoptic is intentionally absent (no working token); MADIS is
added in Phase 2.
"""
import argparse
import csv
import os
import sys
import time
from datetime import datetime, timezone

from common import ICAOS, get, iso, kmh_to_kt, m_to_ft, m_to_sm, pa_to_inhg, hpa_to_inhg

AWC_URL = "https://aviationweather.gov/api/data/metar"
NWS_URL = "https://api.weather.gov/stations/{icao}/observations"

FIELDS = [
    "source", "station", "obs_time", "first_seen", "latency_s", "initial",
    "wdir", "wspd_kt", "wgst_kt", "vis_sm", "ceiling_ft", "lowest_cover",
    "altim_inhg", "temp_c", "dewp_c",
    "wspd_native", "wgst_native", "vis_native", "altim_native", "ceiling_native",
    "receipt_time", "raw",
]
CEILING_COVERS = {"BKN", "OVC", "VV", "OVX"}


def ceiling(layers):
    """layers: [(cover, base)] in any unit. Returns (lowest ceiling base, lowest cover)."""
    ceil = [b for c, b in layers if c in CEILING_COVERS and b is not None]
    lowest = min(layers, key=lambda l: l[1] if l[1] is not None else 1e9)[0] if layers else None
    return (min(ceil) if ceil else None), lowest


def awc_rows():
    r, _, _, _ = get(AWC_URL, params={"ids": ",".join(ICAOS), "format": "json"})
    r.raise_for_status()
    rows = []
    for m in r.json():
        obs = datetime.fromtimestamp(m["obsTime"], timezone.utc)
        layers = [(c.get("cover"), c.get("base")) for c in m.get("clouds") or []]
        ceil_ft, lowest = ceiling(layers)
        vis = m.get("visib")
        rows.append({
            "source": "awc_metar", "station": m["icaoId"], "obs_time": obs,
            "wdir": m.get("wdir"), "wspd_kt": m.get("wspd"), "wgst_kt": m.get("wgst"),
            # visib is a number or a string like "10+"; keep the string as-is.
            "vis_sm": vis, "ceiling_ft": ceil_ft, "lowest_cover": lowest or m.get("cover"),
            "altim_inhg": round(hpa_to_inhg(m["altim"]), 3) if m.get("altim") is not None else None,
            "temp_c": m.get("temp"), "dewp_c": m.get("dewp"),
            "wspd_native": m.get("wspd"), "wgst_native": m.get("wgst"), "vis_native": vis,
            "altim_native": m.get("altim"), "ceiling_native": ceil_ft,
            "receipt_time": m.get("receiptTime"), "raw": m.get("rawOb"),
        })
    return rows


def nws_val(props, key):
    v = props.get(key) or {}
    return v.get("value")


def nws_rows(icao):
    r, _, _, _ = get(NWS_URL.format(icao=icao), params={"limit": 5},
                  headers={"Accept": "application/geo+json"})
    r.raise_for_status()
    rows = []
    for f in r.json().get("features", []):
        p = f["properties"]
        obs = datetime.fromisoformat(p["timestamp"])
        layers = [(l.get("amount"), (l.get("base") or {}).get("value")) for l in p.get("cloudLayers") or []]
        ceil_m, lowest = ceiling(layers)
        wspd, wgst = nws_val(p, "windSpeed"), nws_val(p, "windGust")
        vis, alt = nws_val(p, "visibility"), nws_val(p, "barometricPressure")
        rows.append({
            "source": "nws_api", "station": icao, "obs_time": obs,
            "wdir": nws_val(p, "windDirection"),
            "wspd_kt": None if wspd is None else round(kmh_to_kt(wspd), 1),
            "wgst_kt": None if wgst is None else round(kmh_to_kt(wgst), 1),
            "vis_sm": None if vis is None else round(m_to_sm(vis), 2),
            "ceiling_ft": None if ceil_m is None else round(m_to_ft(ceil_m)),
            "lowest_cover": lowest,
            "altim_inhg": None if alt is None else round(pa_to_inhg(alt), 3),
            "temp_c": nws_val(p, "temperature"), "dewp_c": nws_val(p, "dewpoint"),
            "wspd_native": wspd, "wgst_native": wgst, "vis_native": vis,
            "altim_native": alt, "ceiling_native": ceil_m,
            "receipt_time": None, "raw": p.get("rawMessage") or "",
        })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=int, default=60, help="seconds between polls")
    ap.add_argument("--hours", type=float, default=0, help="stop after N hours (0 = run until killed)")
    ap.add_argument("--out", default=None, help="CSV path (default logs/compare_<UTC start>.csv)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(os.path.join(here, "logs"), exist_ok=True)
    start = datetime.now(timezone.utc)
    out = args.out or os.path.join(here, "logs", f"compare_{start:%Y%m%dT%H%MZ}.csv")
    err_path = out.replace(".csv", "_errors.csv")
    seen = set()
    first_poll = True
    deadline = time.time() + args.hours * 3600 if args.hours else None

    with open(out, "a", newline="") as fh, open(err_path, "a", newline="") as eh:
        w, ew = csv.DictWriter(fh, FIELDS), csv.writer(eh)
        if fh.tell() == 0:
            w.writeheader()
        if eh.tell() == 0:
            ew.writerow(["time", "source", "station", "error"])
        print(f"logging to {out}", flush=True)
        while deadline is None or time.time() < deadline:
            t_poll = time.time()
            jobs = [("awc_metar", "ALL", awc_rows)]
            jobs += [("nws_api", i, (lambda i=i: nws_rows(i))) for i in ICAOS]
            for source, station, fn in jobs:
                try:
                    rows = fn()
                except Exception as e:  # log and keep polling; outages are data too
                    ew.writerow([iso(datetime.now(timezone.utc)), source, station, repr(e)[:300]])
                    eh.flush()
                    continue
                now = datetime.now(timezone.utc)
                for row in rows:
                    key = (row["source"], row["station"], row["obs_time"])
                    if key in seen:
                        continue
                    seen.add(key)
                    row["first_seen"] = iso(now)
                    row["latency_s"] = round((now - row["obs_time"]).total_seconds())
                    row["initial"] = 1 if first_poll else 0
                    row["obs_time"] = iso(row["obs_time"])
                    w.writerow(row)
                fh.flush()
            first_poll = False
            time.sleep(max(0, args.interval - (time.time() - t_poll)))


if __name__ == "__main__":
    sys.exit(main())
