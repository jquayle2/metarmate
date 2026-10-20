"""Dump MADIS 1-minute ASOS (OMO / "HF-METAR") netCDF to per-station JSON.

Reads hourly files from madisPublic1/data/LDAD/hfmetar/netCDF/ (gzipped NETCDF3_CLASSIC),
either .gz or already decompressed. For each requested station it writes every record
with converted units, QC summary (DD) flags, sensor status words and the raw OMO message.

Format notes (from the files themselves):
  - stationId: 4-char ICAO ("KIGM"); dataProvider/stationType are "HF-METAR".
  - observationTime / receivedTime: float seconds since 1970-01-01 UTC.
  - Units: wind m/s, temperature K, altimeter Pa, visibility/layer base/density alt m.
  - Missing: _FillValue 3.4028235e+38 and missing_value -9999; netCDF4 masks both.
    In rawMessage, missing is -999.
  - rawMessage is the original comma-separated OMO message in kt / SM / inHg / ft.
  - Sky: CLR with base 12,500 ft is a sentinel for "nothing below 12,000 ft", not a layer.
    It is never emitted as a layer; see parse_sky.
  - Gust: 254/255 kt with windGustDD "X" (failed QC) is a sentinel, not a gust. In the
    2026-10-15..20 archive, X occurs exactly on the 254/255 kt values (5,559) and never
    elsewhere. wgst_kt is None for it (the raw message still carries 254/255).

Usage: omo_dump.py FILE [FILE ...] [--stations KVGT,KLAS] [--out data/omo_dump.json]
"""
import argparse
import gzip
import json
import os
from collections import Counter, defaultdict
from datetime import datetime, timezone

import netCDF4 as nc
import numpy as np

from common import ICAOS, k_to_c, m_to_ft, m_to_sm, ms_to_kt, pa_to_inhg

DD_VARS = ["temperatureDD", "dewpointDD", "altimeterDD", "windDirDD", "windSpeedDD",
           "windGustDD", "visibilityDD"]
STATUS_VARS = ["siteStatus", "windDirStatus", "windSpeedStatus", "temperatureStatus",
               "dewpointStatus", "pressureStatus", "skyCovLayerBaseStatus", "visibilityStatus",
               "precipOccurTypeStatus", "freezingRainStatus", "runwayVRStatus"]
FILL_FIELDS = ["wdir", "wspd_kt", "wgst_kt", "vis_sm", "sky", "sky_clear_below_12k", "pres_wx", "altim_inhg",
               "temp_c", "dewp_c", "density_alt_ft", "rvr_ft"]


def open_dataset(path):
    if path.endswith(".gz"):
        with gzip.open(path) as fh:
            return nc.Dataset(os.path.basename(path), memory=fh.read())
    return nc.Dataset(path)


def num(v, fn=None, nd=2):
    if np.ma.is_masked(v):
        return None
    v = float(v)
    return round(fn(v) if fn else v, nd)


def text(arr):
    if np.ndim(arr) == 0:  # single-char vars such as the DD QC flags
        return "" if np.ma.is_masked(arr) else bytes(arr).decode("ascii", "replace").strip("\x00 ")
    return str(nc.chartostring(arr)).strip()


def utc(seconds):
    return datetime.fromtimestamp(float(seconds), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


CLEAR_COVERS = {"CLR", "SKC"}


def parse_sky(covers, bases):
    """Return (layers, clear_below_12k).

    Parsing rule (findings H5): OMO reports a clear sky as cover CLR with base 12,500 ft
    (3,810 m). That means "no layers detected below 12,000 ft" (ceilometer limit) and is
    never a real layer, so it is dropped from layers and reported as the flag instead.
    """
    layers, clear = [], False
    for cover, base in zip(nc.chartostring(covers), bases):
        cover = str(cover).strip()
        if not cover:
            continue
        if cover in CLEAR_COVERS:
            clear = True
            continue
        layers.append([cover, num(base, m_to_ft, 0)])
    return layers, clear


def records(ds, stations):
    sid = nc.chartostring(ds["stationId"][:])
    want = np.where(np.isin(sid, list(stations)))[0]
    v = {name: ds[name] for name in ds.variables}
    for i in want:
        sky, sky_clear = parse_sky(v["skyCvr"][i], v["skyCovLayerBase"][i])
        obs, rcv = float(v["observationTime"][i]), float(v["receivedTime"][i])
        yield {
            "icao": str(sid[i]),
            "obs_time": utc(obs),
            "received_time": utc(rcv),
            "receive_lag_s": round(rcv - obs),
            "wdir": num(v["windDir"][i], nd=0),
            "wspd_kt": num(v["windSpeed"][i], ms_to_kt, 1),
            "wgst_kt": None if text(v["windGustDD"][i]) == "X" else num(v["windGust"][i], ms_to_kt, 1),
            "vis_sm": num(v["visibility"][i], m_to_sm, 2),
            "sky": sky,
            "sky_clear_below_12k": sky_clear,
            "pres_wx": text(v["presWx"][i]),
            "altim_inhg": num(v["altimeter"][i], pa_to_inhg, 3),
            "temp_c": num(v["temperature"][i], k_to_c, 1),
            "dewp_c": num(v["dewpoint"][i], k_to_c, 1),
            "density_alt_ft": num(v["densityAltitude"][i], m_to_ft, 0),
            "rvr_ft": num(v["runwayVisualRange"][i], m_to_ft, 0),
            "qc": {k: text(v[k][i]) for k in DD_VARS},
            "status": {k: (None if np.ma.is_masked(v[k][i]) else int(v[k][i])) for k in STATUS_VARS},
            "raw": text(v["rawMessage"][i]),
        }


def populated(rec, field):
    val = rec[field]
    return bool(val) if isinstance(val, (list, str, bool)) else val is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--stations", default=",".join(ICAOS))
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    stations = args.stations.split(",")

    by_station = defaultdict(dict)
    for path in args.files:
        ds = open_dataset(path)
        for rec in records(ds, stations):
            # Same obs can appear in adjacent files; keep the last-read copy.
            by_station[rec["icao"]][rec["obs_time"]] = rec
        ds.close()

    out = {s: [by_station[s][t] for t in sorted(by_station[s])] for s in stations}
    for s in stations:
        recs = out[s]
        if not recs:
            print(f"{s:5} no records")
            continue
        times = [datetime.fromisoformat(r["obs_time"].replace("Z", "+00:00")) for r in recs]
        gaps = Counter(round((b - a).total_seconds() / 60) for a, b in zip(times, times[1:]))
        lags = sorted(r["receive_lag_s"] for r in recs)
        fill = " ".join(f"{f}={sum(populated(r, f) for r in recs)}" for f in FILL_FIELDS)
        print(f"{s:5} n={len(recs)} {recs[0]['obs_time']}..{recs[-1]['obs_time']} "
              f"gaps_min={dict(sorted(gaps.items()))} receive_lag_s(median)={lags[len(lags) // 2]}")
        print(f"      populated: {fill}")

    here = os.path.dirname(os.path.abspath(__file__))
    path = args.out or os.path.join(here, "data", "omo_dump.json")
    with open(path, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"written: {path}")


if __name__ == "__main__":
    main()
