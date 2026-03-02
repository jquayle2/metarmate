#!/usr/bin/env python3
"""
build_airports_from_ourairports.py
Builds MetarMate/Resources/airports.json from OurAirports open data.
Source: https://raw.githubusercontent.com/davidmegginson/ourairports-data/main/airports.csv

Field mapping to Airport struct:
  icao      <- local_code (US FAA ID like "74P") if present, else icao_code, else gps_code
  iata      <- iata_code (if not empty/0)
  name      <- name
  latitude  <- latitude_deg
  longitude <- longitude_deg
  elevation <- elevation_ft (integer, default 0)
  hasMetar  <- False (all entries start false; re-tag with tag_metar_airports.py)

Types kept: small_airport, medium_airport, large_airport, seaplane_base
Types excluded: heliport, balloonport, closed

Run from project root:
  python3 build_airports_from_ourairports.py
"""

import csv
import json
import urllib.request
import io
import sys

CSV_URL = "https://raw.githubusercontent.com/davidmegginson/ourairports-data/main/airports.csv"
OUTPUT  = "MetarMate/Resources/airports.json"

KEEP_TYPES = {"small_airport", "medium_airport", "large_airport", "seaplane_base"}
US_ONLY = True  # Set False to include international airports

def fetch_csv(url):
    print(f"Downloading {url} ...")
    with urllib.request.urlopen(url) as resp:
        raw = resp.read().decode("utf-8")
    print(f"  Downloaded {len(raw):,} bytes")
    return raw

def pick_identifier(row):
    """
    Priority: icao_code (e.g. KLAS) > local_code (e.g. LAS / 74P) > gps_code
    ICAO code is preferred because:
      - It's what the NOAA METAR API expects
      - It's what pilots use for flight planning
      - FAA local codes like "LAS" or "74P" are less useful as primary keys
    Fall back to local_code for airports that have no ICAO (most small US fields).
    """
    icao  = row.get("icao_code", "").strip()
    local = row.get("local_code", "").strip()
    gps   = row.get("gps_code", "").strip()
    return icao or local or gps or None

def clean_iata(val):
    v = val.strip() if val else ""
    return v if v and v != "0" else None

def parse_float(val, default=0.0):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default

def parse_int(val, default=0):
    try:
        return int(float(val))
    except (ValueError, TypeError):
        return default

def main():
    raw = fetch_csv(CSV_URL)
    reader = csv.DictReader(io.StringIO(raw))

    airports = []
    skipped_type = 0
    skipped_no_id = 0
    seen_ids = set()
    dupes = 0

    for row in reader:
        atype = row.get("type", "").strip()
        if atype not in KEEP_TYPES:
            skipped_type += 1
            continue

        if US_ONLY and row.get("iso_country", "").strip() != "US":
            skipped_type += 1
            continue

        identifier = pick_identifier(row)
        if not identifier:
            skipped_no_id += 1
            continue

        if identifier in seen_ids:
            dupes += 1
            continue
        seen_ids.add(identifier)

        airports.append({
            "icao":      identifier,
            "iata":      clean_iata(row.get("iata_code", "")),
            "name":      row.get("name", "").strip(),
            "latitude":  parse_float(row.get("latitude_deg")),
            "longitude": parse_float(row.get("longitude_deg")),
            "elevation": parse_int(row.get("elevation_ft")),
            "hasMetar":  False
        })

    print(f"\nResults:")
    print(f"  Kept:           {len(airports):,}")
    print(f"  Skipped (type): {skipped_type:,}")
    print(f"  Skipped (no id):{skipped_no_id:,}")
    print(f"  Duplicates:     {dupes:,}")

    with open(OUTPUT, "w", encoding="utf-8") as f:
        json.dump(airports, f, separators=(",", ":"))

    import os
    size_mb = os.path.getsize(OUTPUT) / 1_048_576
    print(f"\nWrote {OUTPUT} ({len(airports):,} airports, {size_mb:.1f} MB)")
    print("\nNext step: run tag_metar_airports.py to mark hasMetar=true for NOAA stations")

if __name__ == "__main__":
    main()
