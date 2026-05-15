# Airport Name Quality — Handoff for New Session

## The Problem
Airport names in MetarMate's bundled `airports.json` come from OurAirports and use a truncated `City/Qualifier` format that doesn't match how pilots search or think about airports.

**Example:** KVGT is stored as `"Las Vegas/North Arpt, NV, US"` but every pilot knows it as **"North Las Vegas Airport."** Searching "North Las Vegas" returned zero results until we added multi-word search matching in build 11.

The displayed name on the detail page still shows the awkward OurAirports format.

## What Was Already Fixed (build 11)
- Multi-word search: "North Las Vegas" now *finds* KVGT by matching all words independently
- Relevance sorting: exact ICAO/IATA matches rank highest, METAR airports get a boost

## What Still Needs Fixing
1. **Display names** — The airport name shown on the detail page and in the Nearest/Search lists still uses OurAirports format ("Las Vegas/North Arpt, NV, US")
2. **Slash-format names** — Many airports use `City/Qualifier` format that's unintuitive

## Data Sources Available

### 1. NOAA Station Info API (easiest, already used)
```
https://aviationweather.gov/api/data/stationinfo?ids=KVGT&format=json
```
Returns `"name": "North Las Vegas"` — cleaner but still not "North Las Vegas Airport". We already call this API in `tag_metar_airports.py` to tag `hasMetar`. Could pull names at the same time.

### 2. OurAirports Raw CSV
The build script (`build_airports_from_ourairports.py`) reads from OurAirports CSV. The `name` field there is the source of the problem. Could post-process names in the script.

### 3. BlackboxPi SQLite Database
`/Users/jquayle/code/Pi/BB-V2/airports.sqlite` — 19,594 US airports from a different source. May have better names. Worth comparing.

### 4. FAA NASR Data
Official FAA names, available as downloadable dataset. Most authoritative but requires additional data pipeline work.

## Suggested Approach
The quickest win is probably modifying `tag_metar_airports.py` (which already hits NOAA) to also pull the station name for METAR airports, and falling back to a cleaned-up OurAirports name for non-METAR airports. The cleanup could be:
- Detect slash format: `"Las Vegas/North Arpt"` → reverse to `"North Las Vegas Airport"`
- Strip redundant state/country suffix if already in a separate field
- Expand common abbreviations: "Arpt" → "Airport", "Intl" → "International", "Muni" → "Municipal", "Rgn" → "Regional"

## Files to Modify
- `build_airports_from_ourairports.py` — main build script, add name cleanup/NOAA override
- `tag_metar_airports.py` — already calls NOAA stationinfo, add name extraction
- `MetarMate/Resources/airports.json` — regenerate after script changes
- Same change needed for Android: `app/src/main/assets/airports.json`

## How to Test
After regenerating `airports.json`, spot-check these airports:
- KVGT — should be "North Las Vegas Airport" (not "Las Vegas/North Arpt")
- KLAS — should be "Las Vegas/Reid Intl" or "Harry Reid International Airport"
- KSFO — should be "San Francisco International Airport"
- KJFK — should be "John F Kennedy International Airport"
- KORD — should be "Chicago O'Hare International Airport"

Search for these by common name and verify they appear and display correctly.
