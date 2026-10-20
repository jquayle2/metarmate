"""Scale test: OMO (hfmetar archive) vs official METAR, sky/ceiling and gust.

Inputs: hourly OMO files (data/hfmetar/archive/*.gz) and METAR history from
fetch_metar_history.py (data/metars/<ICAO>.json). Only the overlap of the OMO span and
the METAR span is analysed (reported with station-hours and gust-event counts). Each METAR
in it is paired with the nearest OMO record for its station within +/- --window-min.

AUTO vs augmented: a METAR is "AUTO" if its text carries the AUTO modifier, otherwise
"augmented" (an observer was involved). For the sky test, stations are classified by
the share of their METARs that are AUTO (1.0 = AUTO-only, 0.0 = never AUTO), and up to
--per-group CONUS stations (K + 3 chars) are sampled from each pure group with a fixed seed.

Sky/ceiling metrics (per paired METAR):
  - flight category agreement (FAA: LIFR cig<500 or vis<1; IFR cig<1000 or vis<3;
    MVFR cig<=3000 or vis<=5; else VFR). Same function both sides.
  - ceiling agreement: both none, or |delta| <= 100 ft when the METAR ceiling is below
    5,000 ft, <= 500 ft at or above 5,000 ft. Also with both sides restricted to layers
    <= 12,000 ft (ceil_agree_12k); disagreement examples are drawn from that metric.
  OMO records with no sky group at all are counted as omo_sky_missing and excluded.
  - layer agreement: same layer count and same coverage sequence; also with both sides
    restricted to layers <= 12,000 ft (the classic ceilometer range; some ASOS ceilometers
    report higher, e.g. KADF 22,000 ft in OMO and METAR alike).
  OMO CLR/12,500 ft is a sentinel, never a layer (findings H5).
  OMO gust 254/255 kt with windGustDD "X" is a sentinel, read as no gust (see omo_dump).

Gust (all stations): for each METAR whose wind group has G, does the nearest OMO record
carry a gust, and the delta (OMO - METAR, kt) when it does. Caveat: OMO files keep only
the 5-minute marks, while a METAR gust is the peak of the last 10 minutes; so also: does
any OMO record from 10 min before to --window-min after the METAR carry a gust, and the
delta of the largest one (gust_10min).

Writes logs/scale_results_<UTC>.json and prints a summary.
"""
import argparse
import glob
import json
import os
import random
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone

import netCDF4 as nc
import numpy as np

from common import m_to_ft, m_to_sm, ms_to_kt
from omo_dump import open_dataset

HERE = os.path.dirname(os.path.abspath(__file__))
GUST = re.compile(r"\b(?:\d{3}|VRB)\d{2,3}G(\d{2,3})KT\b")
CEIL = {"BKN", "OVC", "OVX", "VV"}
CLEAR = {"CLR", "SKC", "CAVOK", "NCD", "NSC"}


def load_omo(paths):
    """station -> (sorted times array, list of records). Records are small dicts."""
    by = defaultdict(dict)
    for p in paths:
        ds = open_dataset(p)
        sid = nc.chartostring(ds["stationId"][:])
        t = ds["observationTime"][:]
        gust = ds["windGust"][:]
        gust_x = np.ma.filled(ds["windGustDD"][:], b" ") == b"X"
        vis = ds["visibility"][:]
        cov = nc.chartostring(ds["skyCvr"][:])
        base = ds["skyCovLayerBase"][:]
        for i in range(len(sid)):
            if np.ma.is_masked(t[i]):
                continue
            layers, reported = [], False
            for c, b in zip(cov[i], base[i]):
                c = str(c).strip()
                reported |= bool(c)
                if c and c not in CLEAR:
                    layers.append((c, None if np.ma.is_masked(b) else round(m_to_ft(float(b)))))
            by[str(sid[i])][int(t[i])] = {
                "gust": None if np.ma.is_masked(gust[i]) or gust_x[i] else ms_to_kt(float(gust[i])),
                "vis": None if np.ma.is_masked(vis[i]) else m_to_sm(float(vis[i])),
                "layers": layers,
                "sky_reported": reported,  # False = no sky group at all (missing, not clear)
            }
        ds.close()
    out = {}
    for s, recs in by.items():
        ts = np.array(sorted(recs))
        out[s] = (ts, [recs[x] for x in ts])
    return out


def nearest(omo, icao, t, window_s):
    if icao not in omo:
        return None, None
    ts, recs = omo[icao]
    j = np.searchsorted(ts, t)
    best = None
    for k in (j - 1, j):
        if 0 <= k < len(ts) and abs(ts[k] - t) <= window_s:
            if best is None or abs(ts[k] - t) < abs(ts[best] - t):
                best = k
    return (None, None) if best is None else (recs[best], int(ts[best] - t))


def in_range(omo, icao, t0, t1):
    if icao not in omo:
        return []
    ts, recs = omo[icao]
    return recs[np.searchsorted(ts, t0):np.searchsorted(ts, t1, side="right")]


def summarize(d):
    return ({"n": len(d), "median": float(np.median(d)), "mean": round(float(np.mean(d)), 2),
             "abs_le_2": round(sum(abs(x) <= 2 for x in d) / len(d), 3),
             "hist": dict(sorted(Counter(d).items()))} if d else None)


def metar_vis(m):
    v = m.get("visib")
    if v is None:
        return None
    try:
        return float(str(v).rstrip("+"))
    except ValueError:
        return None


def metar_layers(m):
    out = []
    for c in m.get("clouds") or []:
        cov = c.get("cover")
        if cov and cov not in CLEAR:
            out.append((cov, c.get("base")))
    return out


def ceiling(layers):
    c = [b for cov, b in layers if cov in CEIL and b is not None]
    return min(c) if c else None


def category(cig, vis):
    if vis is None:
        return None
    if (cig is not None and cig < 500) or vis < 1:
        return "LIFR"
    if (cig is not None and cig < 1000) or vis < 3:
        return "IFR"
    if (cig is not None and cig <= 3000) or vis <= 5:
        return "MVFR"
    return "VFR"


def ceil_agree(mc, oc):
    if mc is None and oc is None:
        return True
    if mc is None or oc is None:
        return False
    return abs(mc - oc) <= (100 if mc < 5000 else 500)


def covers(layers, top=None):
    return tuple(c if c != "OVX" else "VV" for c, b in layers if top is None or (b is not None and b <= top))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--omo-glob", default=os.path.join(HERE, "data", "hfmetar", "archive", "*.gz"))
    ap.add_argument("--window-min", type=int, default=5)
    ap.add_argument("--per-group", type=int, default=50)
    ap.add_argument("--seed", type=int, default=20261020)
    args = ap.parse_args()
    window = args.window_min * 60

    files = sorted(glob.glob(args.omo_glob))
    omo = load_omo(files)
    span = (min(v[0][0] for v in omo.values()), max(v[0][-1] for v in omo.values()))
    raw = {os.path.basename(p)[:-5]: json.load(open(p))
           for p in glob.glob(os.path.join(HERE, "data", "metars", "*.json"))}
    times = [m["obsTime"] for ms in raw.values() for m in ms]
    mspan = (min(times), max(times))
    # Analyse only the overlap of the two sources; the archive rolls, so don't assume 5 days.
    overlap = (max(span[0], mspan[0]), min(span[1], mspan[1]))
    metars = {}
    for icao, ms in raw.items():
        ms = [m for m in ms if overlap[0] <= m["obsTime"] <= overlap[1]]
        if ms:
            metars[icao] = ms
    iso = lambda s: datetime.fromtimestamp(s, timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    kind = lambda m: "AUTO" if " AUTO " in m["rawOb"] else "augmented"
    sh, gev = defaultdict(set), Counter()
    for s, ms in metars.items():
        for m in ms:
            sh[kind(m)].add((s, m["obsTime"] // 3600))
            gev[kind(m)] += bool(GUST.search(m["rawOb"]))
    res = {"omo_files": len(files), "omo_span": [iso(span[0]), iso(span[1])],
           "metar_span": [iso(mspan[0]), iso(mspan[1])],
           "overlap": [iso(overlap[0]), iso(overlap[1])],
           "overlap_hours": round((overlap[1] - overlap[0]) / 3600, 1),
           "omo_stations": len(omo), "metar_stations": len(metars),
           "metars_in_overlap": sum(len(v) for v in metars.values()),
           "station_hours": {k: len(v) for k, v in sh.items()},
           "gust_metar_events": dict(gev)}

    # --- station classification by AUTO share
    share = {s: sum(" AUTO " in m["rawOb"] for m in ms) / len(ms) for s, ms in metars.items()}
    conus = lambda s: len(s) == 4 and s.startswith("K") and s in omo
    groups = {"AUTO": sorted(s for s, v in share.items() if v == 1.0 and conus(s)),
              "augmented": sorted(s for s, v in share.items() if v == 0.0 and conus(s))}
    res["station_classes"] = {"auto_only": len(groups["AUTO"]), "never_auto": len(groups["augmented"]),
                              "mixed": sum(1 for v in share.values() if 0 < v < 1)}
    rng = random.Random(args.seed)
    sample = {g: sorted(rng.sample(v, min(args.per_group, len(v)))) for g, v in groups.items()}
    res["sample"] = sample

    # --- sky / ceiling
    sky = {}
    for g, stations in sample.items():
        c = Counter()
        cat_conf = Counter()
        examples = []
        for s in stations:
            for m in metars[s]:
                rec, dt = nearest(omo, s, m["obsTime"], window)
                if rec is None:
                    c["no_omo"] += 1
                    continue
                c["pairs"] += 1
                if not rec["sky_reported"]:
                    c["omo_sky_missing"] += 1
                    continue
                c["sky_pairs"] += 1
                ml, ol = metar_layers(m), rec["layers"]
                mc, oc = ceiling(ml), ceiling(ol)
                mcat, ocat = category(mc, metar_vis(m)), category(oc, rec["vis"])
                if mcat and ocat:
                    c["cat_pairs"] += 1
                    c["cat_agree"] += mcat == ocat
                    cat_conf[f"{mcat}->{ocat}"] += 1
                ok = ceil_agree(mc, oc)
                c["ceil_agree"] += ok
                if mc is not None or oc is not None:
                    c["ceil_any"] += 1
                    c["ceil_any_agree"] += ok
                ml12 = [l for l in ml if l[1] is not None and l[1] <= 12000]
                ol12 = [l for l in ol if l[1] is not None and l[1] <= 12000]
                ok12 = ceil_agree(ceiling(ml12), ceiling(ol12))
                c["ceil_agree_12k"] += ok12
                c["count_agree"] += len(ml) == len(ol)
                c["cover_agree"] += covers(ml) == covers(ol)
                c["count_agree_12k"] += len(ml12) == len(ol12)
                c["cover_agree_12k"] += covers(ml12) == covers(ol12)
                if not ok12 and len(examples) < 12:
                    examples.append({"station": s, "metar": m["rawOb"], "omo_dt_s": dt,
                                     "omo_layers": ol, "metar_ceiling": mc, "omo_ceiling": oc})
        sky[g] = {"counts": dict(c), "category_pairs": dict(cat_conf.most_common()), "ceiling_disagree_examples": examples}
    res["sky"] = sky

    # --- gust, all stations
    gust = {"AUTO": Counter(), "augmented": Counter()}
    deltas = {"AUTO": [], "augmented": []}
    deltas10 = {"AUTO": [], "augmented": []}
    misses = {"AUTO": [], "augmented": []}
    for s, ms in metars.items():
        for m in ms:
            g = GUST.search(m["rawOb"])
            if not g:
                continue
            k = "AUTO" if " AUTO " in m["rawOb"] else "augmented"
            gust[k]["gust_metars"] += 1
            rec, dt = nearest(omo, s, m["obsTime"], window)
            if rec is None:
                gust[k]["not_covered"] += 1
                continue
            gust[k]["paired"] += 1
            g10 = [r["gust"] for r in in_range(omo, s, m["obsTime"] - 600, m["obsTime"] + window)
                   if r["gust"] is not None]
            if g10:
                gust[k]["omo_gust_10min"] += 1
                deltas10[k].append(round(max(g10)) - int(g.group(1)))
            if rec["gust"] is None:
                gust[k]["omo_no_gust"] += 1
                if len(misses[k]) < 8:
                    misses[k].append({"metar": m["rawOb"], "omo_dt_s": dt})
            else:
                gust[k]["omo_gust"] += 1
                deltas[k].append(round(rec["gust"]) - int(g.group(1)))
    res["gust"] = {}
    for k in gust:
        d = deltas[k]
        res["gust"][k] = {
            "counts": dict(gust[k]),
            "share_paired_with_gust": round(gust[k]["omo_gust"] / gust[k]["paired"], 3) if gust[k]["paired"] else None,
            "delta_kt": summarize(d),
            "share_paired_with_gust_10min": round(gust[k]["omo_gust_10min"] / gust[k]["paired"], 3) if gust[k]["paired"] else None,
            "delta_kt_10min_max": summarize(deltas10[k]),
            "examples_no_gust": misses[k],
        }

    path = os.path.join(HERE, "logs", f"scale_results_{datetime.now(timezone.utc):%Y%m%dT%H%MZ}.json")
    with open(path, "w") as fh:
        json.dump(res, fh, indent=1)
    print(json.dumps({k: v for k, v in res.items() if k != "sample"}, indent=1)[:12000])
    print(f"written: {path}")


if __name__ == "__main__":
    main()
