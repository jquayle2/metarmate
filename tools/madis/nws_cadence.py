"""Phase 1.2: api.weather.gov observation cadence per station.

Pulls the last --hours of /stations/{ICAO}/observations and reports, per station:
obs count, interval distribution, age of the newest obs, and which fields are populated
on "off-hour" obs (no rawMessage, i.e. not a METAR/SPECI) vs METAR obs.

Raw JSON goes to data/nws_<ICAO>_<UTC>.json; a summary JSON goes to logs/.
"""
import argparse
import json
import os
from collections import Counter
from datetime import datetime, timedelta, timezone

from common import STATIONS, get, iso

URL = "https://api.weather.gov/stations/{icao}/observations"
FIELDS = ["temperature", "dewpoint", "windDirection", "windSpeed", "windGust",
          "barometricPressure", "seaLevelPressure", "visibility", "presentWeather", "cloudLayers"]


def populated(p, key):
    v = p.get(key)
    if isinstance(v, list):
        return len(v) > 0
    return isinstance(v, dict) and v.get("value") is not None


def summarize(icao, feats, now):
    obs = sorted(feats, key=lambda f: f["properties"]["timestamp"])
    times = [datetime.fromisoformat(f["properties"]["timestamp"]) for f in obs]
    gaps = Counter(round((b - a).total_seconds() / 60) for a, b in zip(times, times[1:]))
    groups = {"metar": [], "offhour": []}
    for f in obs:
        p = f["properties"]
        groups["metar" if p.get("rawMessage") else "offhour"].append(p)
    fill = {g: {k: sum(populated(p, k) for p in ps) for k in FIELDS} for g, ps in groups.items()}
    return {
        "icao": icao,
        "count": len(obs),
        "metar_count": len(groups["metar"]),
        "offhour_count": len(groups["offhour"]),
        "first": iso(times[0]) if times else None,
        "newest": iso(times[-1]) if times else None,
        "newest_age_min": round((now - times[-1]).total_seconds() / 60) if times else None,
        "interval_min_counts": dict(sorted(gaps.items())),
        "populated": fill,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=6)
    args = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(os.path.join(here, "data"), exist_ok=True)
    os.makedirs(os.path.join(here, "logs"), exist_ok=True)
    now = datetime.now(timezone.utc)
    start = now - timedelta(hours=args.hours)
    stamp = f"{now:%Y%m%dT%H%MZ}"
    out = {"run_at": iso(now), "window_hours": args.hours, "stations": []}

    for s in STATIONS:
        icao = s["icao"]
        try:
            r, fetched, elapsed, attempts = get(URL.format(icao=icao),
                                                params={"start": iso(start)},
                                                headers={"Accept": "application/geo+json"})
        except Exception as e:
            out["stations"].append({"icao": icao, "error": repr(e)[:300]})
            print(f"{icao}: ERROR {e!r}"[:200])
            continue
        entry = {"icao": icao, "type": s["type"], "http": r.status_code,
                 "fetched": iso(fetched), "elapsed_s": round(elapsed, 2), "attempts": attempts}
        if r.status_code == 200:
            feats = r.json().get("features", [])
            with open(os.path.join(here, "data", f"nws_{icao}_{stamp}.json"), "w") as fh:
                json.dump(r.json(), fh)
            entry.update(summarize(icao, feats, fetched))
        out["stations"].append(entry)
        print(f"{icao:5} {s['type']:9} http={r.status_code} n={entry.get('count')} "
              f"metar={entry.get('metar_count')} off={entry.get('offhour_count')} "
              f"newest={entry.get('newest')} age={entry.get('newest_age_min')}m "
              f"gaps={entry.get('interval_min_counts')}")

    path = os.path.join(here, "logs", f"nws_cadence_{stamp}.json")
    with open(path, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"summary: {path}")


if __name__ == "__main__":
    main()
