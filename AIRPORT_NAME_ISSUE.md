# Airport Name Quality Issue

## Problem
Airport names in MetarMate's bundled `airports.json` use truncated/reformatted names from OurAirports that don't always match how pilots search for them.

### Example
- **KVGT** is stored as: `"Las Vegas/North Arpt, NV, US"`
- **Pilots search for**: "North Las Vegas Airport" or "North Las Vegas"
- The slash-separated format and truncation make natural-language searches fail

### Other likely affected airports
Any airport where OurAirports uses the `City/Qualifier` format instead of the common name:
- `Las Vegas/North Arpt` → should be `North Las Vegas Airport`
- Similar patterns likely exist for airports like `Chicago/Midway`, `New York/Kennedy`, etc.

## Root Cause
The `build_airports_from_ourairports.py` script takes the `name` field directly from OurAirports CSV without cleanup. OurAirports uses a `City/Qualifier` naming convention that differs from FAA official names.

## Current Mitigation (build 11)
Multi-word search was added so "North Las Vegas" will match "Las Vegas/North Arpt" (each word matched independently). This helps discoverability but the displayed name is still odd.

## Potential Fixes (investigate in future session)

### Option 1: Cross-reference with NOAA station info
NOAA's `stationinfo` API returns proper airport names. We already call this for `hasMetar` tagging. Could pull the name from NOAA for METAR stations:
```
https://aviationweather.gov/api/data/stationinfo?ids=KVGT&format=json
```
Returns `"name": "North Las Vegas"` — cleaner but still not "North Las Vegas Airport".

### Option 2: Cross-reference with FAA NASR data
The FAA's National Airspace System Resource (NASR) database has official airport names. Available as a download or via API.

### Option 3: Clean up in build script
Post-process OurAirports names:
- Detect `City/Qualifier` pattern (contains `/`)
- Reverse to `Qualifier City` format
- Strip state/country suffix if redundant
- Append "Airport" if missing

### Option 4: Use the BlackboxPi SQLite database
`/Users/jquayle/Documents/Pi/BB-V2/airports.sqlite` has 19,594 US airports and may have better name data. Worth comparing.

## Files Involved
- `build_airports_from_ourairports.py` — build script that generates airports.json
- `MetarMate/Resources/airports.json` — bundled database (~14,753 airports)
- `tag_metar_airports.py` — already calls NOAA stationinfo, could pull names too
- `/Users/jquayle/Documents/Pi/BB-V2/airports.sqlite` — alternative data source
