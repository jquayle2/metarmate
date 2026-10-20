"""Ground-truth check of api.weather.gov unit conversions against METAR text.

For every api.weather.gov obs in the latest data/nws_<ICAO>_*.json that carries a
rawMessage (i.e. it *is* a METAR/SPECI), parse the METAR text and compare it with the
converted SI values. Also pulls 24 h of aviationweather.gov METARs and lists every gust,
so gust coverage on api.weather.gov can be judged against what the METARs reported.

Mismatches are printed, not "fixed".
"""
import glob
import json
import os
import re
from datetime import datetime, timezone

from common import ICAOS, get, kmh_to_kt, m_to_sm, pa_to_inhg

HERE = os.path.dirname(os.path.abspath(__file__))
WIND = re.compile(r"\b(\d{3}|VRB)(\d{2,3})(?:G(\d{2,3}))?KT\b")
VIS = re.compile(r"\b(M?)(\d+(?: \d/\d)?|\d/\d)SM\b")
ALT = re.compile(r"\bA(\d{4})\b")
TT = re.compile(r"\bT([01])(\d{3})([01])(\d{3})\b")


def vis_sm(m):
    s = m.group(2)
    if " " in s:
        w, f = s.split()
        n, d = f.split("/")
        return int(w) + int(n) / int(d)
    if "/" in s:
        n, d = s.split("/")
        return int(n) / int(d)
    return float(s)


def val(p, k):
    return (p.get(k) or {}).get("value")


def check_station(icao):
    files = sorted(glob.glob(os.path.join(HERE, "data", f"nws_{icao}_*.json")))
    if not files:
        return []
    out = []
    for f in json.load(open(files[-1]))["features"]:
        p = f["properties"]
        raw = p.get("rawMessage") or ""
        if not raw:
            continue
        rec = {"icao": icao, "time": p["timestamp"], "raw": raw, "issues": []}
        if w := WIND.search(raw):
            spd, gst = int(w.group(2)), w.group(3) and int(w.group(3))
            n_spd = val(p, "windSpeed")
            n_gst = val(p, "windGust")
            c_spd = None if n_spd is None else kmh_to_kt(n_spd)
            if c_spd is None or round(c_spd) != spd:
                rec["issues"].append(f"wind {spd}kt vs nws {n_spd} km/h -> {c_spd and round(c_spd, 2)} kt")
            c_gst = None if n_gst is None else kmh_to_kt(n_gst)
            if (gst or None) != (None if c_gst is None else round(c_gst)):
                rec["issues"].append(f"gust {gst} vs nws {n_gst} km/h -> {c_gst and round(c_gst, 2)}")
            if w.group(1) != "VRB" and val(p, "windDirection") != int(w.group(1)):
                rec["issues"].append(f"dir {w.group(1)} vs nws {val(p, 'windDirection')}")
        if v := VIS.search(raw):
            n_vis = val(p, "visibility")
            c = None if n_vis is None else m_to_sm(n_vis)
            if c is None or abs(c - vis_sm(v)) > 0.01:
                rec["issues"].append(f"vis {v.group(0)} vs nws {n_vis} m -> {c and round(c, 3)} SM")
        if a := ALT.search(raw):
            n_alt = val(p, "barometricPressure")
            c = None if n_alt is None else pa_to_inhg(n_alt)
            if c is None or round(c, 2) != int(a.group(1)) / 100:
                rec["issues"].append(f"alt {a.group(0)} vs nws {n_alt} Pa -> {c and round(c, 3)} inHg")
        if t := TT.search(raw):
            tc = (-1 if t.group(1) == "1" else 1) * int(t.group(2)) / 10
            dc = (-1 if t.group(3) == "1" else 1) * int(t.group(4)) / 10
            if val(p, "temperature") is None or abs(val(p, "temperature") - tc) > 0.05:
                rec["issues"].append(f"temp T-group {tc} vs nws {val(p, 'temperature')}")
            if val(p, "dewpoint") is None or abs(val(p, "dewpoint") - dc) > 0.05:
                rec["issues"].append(f"dewp T-group {dc} vs nws {val(p, 'dewpoint')}")
        out.append(rec)
    return out


def main():
    total = bad = 0
    for icao in ICAOS:
        for rec in check_station(icao):
            total += 1
            if rec["issues"]:
                bad += 1
                print(f"{rec['icao']} {rec['time']}: " + "; ".join(rec["issues"]))
                print(f"    {rec['raw']}")
    print(f"\nMETAR-bearing api.weather.gov obs checked: {total}, with any mismatch: {bad}")

    r, *_ = get("https://aviationweather.gov/api/data/metar",
                params={"ids": ",".join(ICAOS), "format": "json", "hours": 24})
    r.raise_for_status()
    gusts = [(m["icaoId"], datetime.fromtimestamp(m["obsTime"], timezone.utc).strftime("%m-%dT%H:%MZ"), m["rawOb"])
             for m in r.json() if WIND.search(m.get("rawOb", "")) and WIND.search(m["rawOb"]).group(3)]
    print(f"\nAWC METARs with gusts, last 24 h: {len(gusts)} (of {len(r.json())} METARs)")
    for g in sorted(gusts):
        print("  ", *g)


if __name__ == "__main__":
    main()
