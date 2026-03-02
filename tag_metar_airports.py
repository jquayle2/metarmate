"""
tag_metar_airports.py
Cross-references MetarMate airports.json against NOAA stationinfo API.
Adds hasMetar: true/false to each airport entry.
Output: airports_tagged.json (drop-in replacement for airports.json)
Usage: python3 tag_metar_airports.py
"""
import json, time, urllib.request, urllib.parse
from pathlib import Path

AIRPORTS_IN  = Path(__file__).parent / "MetarMate/Resources/airports.json"
AIRPORTS_OUT = Path(__file__).parent / "MetarMate/Resources/airports_tagged.json"
BATCH_SIZE   = 200
SLEEP_SEC    = 0.4
API_BASE     = "https://aviationweather.gov/api/data/stationinfo"

def fetch_station_batch(icao_ids):
    ids_param = ",".join(icao_ids)
    url = f"{API_BASE}?ids={urllib.parse.quote(ids_param)}&format=json"
    req = urllib.request.Request(url, headers={"User-Agent": "MetarMate-Tagger/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            stations = json.loads(resp.read().decode())
    except Exception as e:
        print(f"  WARNING: batch failed ({e}), retrying...")
        time.sleep(2)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                stations = json.loads(resp.read().decode())
        except Exception as e2:
            print(f"  ERROR: retry failed ({e2}). Marking batch as no-METAR.")
            return set()
    return {s["id"] for s in stations if "METAR" in s.get("siteType", [])}

def main():
    print(f"Loading {AIRPORTS_IN}...")
    airports = json.loads(AIRPORTS_IN.read_text())
    print(f"  {len(airports)} airports loaded.")
    all_icaos = [a["icao"] for a in airports]
    metar_stations = set()
    total_batches = (len(all_icaos) + BATCH_SIZE - 1) // BATCH_SIZE
    print(f"\nQuerying NOAA in {total_batches} batches of {BATCH_SIZE}...")
    for i in range(0, len(all_icaos), BATCH_SIZE):
        batch = all_icaos[i:i+BATCH_SIZE]
        batch_num = i // BATCH_SIZE + 1
        found = fetch_station_batch(batch)
        metar_stations |= found
        print(f"  Batch {batch_num}/{total_batches}: sent {len(batch)}, got {len(found)} METAR (running total: {len(metar_stations)})")
        if batch_num < total_batches:
            time.sleep(SLEEP_SEC)
    print(f"\nTotal METAR-capable stations: {len(metar_stations)}")
    tagged = []
    yes_count = no_count = 0
    for a in airports:
        has = a["icao"] in metar_stations
        tagged.append({"icao": a["icao"], "iata": a.get("iata"), "name": a["name"],
                       "latitude": a["latitude"], "longitude": a["longitude"],
                       "elevation": a["elevation"], "hasMetar": has})
        if has: yes_count += 1
        else:   no_count  += 1
    print(f"  hasMetar=true:  {yes_count}")
    print(f"  hasMetar=false: {no_count}")
    print(f"\nWriting {AIRPORTS_OUT}...")
    AIRPORTS_OUT.write_text(json.dumps(tagged, indent=2, ensure_ascii=False))
    print("Done! Verify airports_tagged.json then rename to airports.json.")
    print("\n-- Spot-check --")
    lookup = {a["icao"]: a for a in tagged}
    for icao in ["KLAS","KLAX","KORD","KJFK","KDEN","KACZ","KPVF"]:
        if icao in lookup:
            a = lookup[icao]
            print(f"  {icao:6s}  hasMetar={str(a['hasMetar']):<5}  {a['name']}")
        else:
            print(f"  {icao:6s}  not in database")

if __name__ == "__main__":
    main()
