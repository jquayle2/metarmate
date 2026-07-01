#!/usr/bin/env python3
"""
merge_airport_names.py - Refresh MetarMate's airports.json display names from FAA NASR.

WHY: The OurAirports-derived airports.json carries mangled display names like
"Las Vegas/North Arpt, NV, US". FAA NASR's APT_BASE.csv carries the official
facility name in ARPT_NAME ("NORTH LAS VEGAS"), which is what ForeFlight displays.
This script overwrites the `name` field (and adds `city`/`state`) from NASR wherever
there's a match, keyed by ICAO first then FAA LID (so numeric IDs like 36K/0L7 are
covered). No-match airports keep their OurAirports name. lat/lon/elev/iata/hasMetar
are never touched.

NASR refreshes every 28 days (same cadence as merge_runways.py):
  python3 merge_airport_names.py --nasr /path/nasr_csv \
    --airports .../Resources/airports.json --out .../airports.json.new --title-expand
Then review the printed validation and copy the .new over airports.json.
"""
import csv, json, argparse, os, re

EXPAND = {
    'INTL': 'International', 'MUNI': 'Municipal', 'EXEC': 'Executive',
    'RGNL': 'Regional', 'MEM': 'Memorial', 'MEML': 'Memorial', 'FLD': 'Field',
    'CO': 'County', 'CNTY': 'County', 'MTN': 'Mountain', 'SPB': 'Seaplane Base',
    'NATL': 'National', 'NTL': 'National',
}
KEEP_UPPER = {'AFB', 'ANGB', 'ARB', 'NAS', 'NALF', 'AAF', 'AHP', 'MCAS',
              'CGAS', 'USAF', 'US', 'AF', 'II', 'III', 'IV'}

# Split a token on internal separators, KEEPING the separators, so each
# alpha run gets its own capitalization: "HARTSFIELD/JACKSON" -> the '/' is
# preserved and "JACKSON" is capitalized independently. Fixes O'HARE, slashes,
# hyphens, and parens ("NAS (REEVES FLD)") that str.capitalize() lowercased.
SEP_RE = re.compile(r"([ /'\-()])")
SEP_CHARS = frozenset(" /'-()")


def cap_word(w):
    """Capitalize one alpha run, with Mc/Mac handling.

    ForeFlight (verified via NASR + FF screenshots) titleizes whatever NASR
    stores and does NOT normalize spacing: closed-up "MCKINNEY" -> "McKinney",
    "MCMINN" -> "McMinn"; but spaced "MC CLELLAN"/"MC MAHON" stay two tokens and
    render "Mc Clellan"/"Mc Mahon". So the only special case is a closed-up
    Mc/Mac prefix inside a single token; the spaced form is handled by normal
    per-run capitalization.
    """
    if not w:
        return w
    low = w.lower()
    if len(low) > 2 and low.startswith('mc') and low[2:].isalpha():
        return 'Mc' + low[2].upper() + low[3:]
    if len(low) > 3 and low.startswith('mac') and low[3:].isalpha():
        return 'Mac' + low[3].upper() + low[4:]
    return w[:1].upper() + w[1:].lower()


def titleize(name, expand):
    out = []
    for tok in name.split():
        up = tok.upper()
        if up in KEEP_UPPER:
            out.append(up)
        elif expand and up in EXPAND:
            out.append(EXPAND[up])
        elif any(ch.isdigit() for ch in tok):
            out.append(tok)  # leave IDs / alphanumeric tokens untouched
        else:
            parts = SEP_RE.split(tok)
            rebuilt = []
            for p in parts:
                if p in SEP_CHARS:
                    rebuilt.append(p)
                else:
                    up2 = p.upper()
                    if up2 in KEEP_UPPER:
                        rebuilt.append(up2)
                    elif expand and up2 in EXPAND:
                        rebuilt.append(EXPAND[up2])
                    else:
                        rebuilt.append(cap_word(p))
            out.append(''.join(rebuilt))
    # collapse any incidental double spaces (some NASR names carry them, e.g.
    # around a spaced hyphen "KONOCTI  - CLEAR LAKE")
    return re.sub(r'\s{2,}', ' ', ' '.join(out)).strip()


def city_title(city):
    # Same separator-aware titleizing as facility names (never expand abbrevs),
    # so "CHICAGO/SCHAUMBURG" -> "Chicago/Schaumburg", not "Chicago/schaumburg".
    if not city:
        return ''
    return titleize(city, expand=False)


def load_nasr(nasr_dir, expand):
    base = os.path.join(nasr_dir, 'APT_BASE.csv')
    by_icao, by_lid = {}, {}
    for r in csv.DictReader(open(base)):
        if r['SITE_TYPE_CODE'] != 'A':
            continue
        raw = (r['ARPT_NAME'] or '').strip()
        if not raw:
            continue
        rec = {'name': titleize(raw, expand),
               'city': city_title((r['CITY'] or '').strip()),
               'state': (r['STATE_CODE'] or '').strip()}
        icao = (r['ICAO_ID'] or '').strip()
        lid = (r['ARPT_ID'] or '').strip()
        if icao:
            by_icao[icao] = rec
        if lid:
            by_lid[lid] = rec
    return by_icao, by_lid


def merge(nasr_dir, airports_path, out_path, expand, add_city):
    by_icao, by_lid = load_nasr(nasr_dir, expand)
    print(f'NASR names loaded: {len(by_icao)} by ICAO, {len(by_lid)} by LID')

    airports = json.load(open(airports_path))
    matched = unmatched = 0
    hit_by = {'icao': 0, 'lid_raw': 0, 'lid_stripK': 0, 'iata': 0}
    for a in airports:
        # NOTE: the "icao" field in airports.json is a misnomer. Only ~2,256 of
        # ~14,753 records hold a true K-prefixed ICAO; the other ~12,500 store a
        # raw FAA LID directly here (36K, 0L7, 06C, L35, 00AA...). NASR keys those
        # by ARPT_ID (== by_lid). So we must try the RAW icao value against by_lid,
        # not just the len==3 case the old code handled.
        icao = (a.get('icao') or '').strip()
        iata = (a.get('iata') or '').strip()

        rec = by_icao.get(icao)
        if rec is not None:
            hit_by['icao'] += 1
        if rec is None:
            rec = by_lid.get(icao)          # raw LID stored in the icao field
            if rec is not None:
                hit_by['lid_raw'] += 1
        if rec is None and icao.startswith('K') and len(icao) == 4:
            rec = by_lid.get(icao[1:])      # KXXX -> XXX LID (e.g. K36K -> 36K)
            if rec is not None:
                hit_by['lid_stripK'] += 1
        if rec is None and iata:
            rec = by_lid.get(iata)
            if rec is not None:
                hit_by['iata'] += 1

        if rec:
            a['name'] = rec['name']
            if add_city:
                a['city'] = rec['city']
                a['state'] = rec['state']
            matched += 1
        else:
            unmatched += 1

    json.dump(airports, open(out_path, 'w'), ensure_ascii=False,
              separators=(',', ':'))
    print(f'Merged: {matched} refreshed, {unmatched} kept OurAirports fallback')
    print(f'  hit source: {hit_by}')
    print(f'Wrote {out_path}')

    # keys as actually stored in airports.json (LID-keyed records store the bare
    # LID in the "icao" field, e.g. '36K', not 'K36K')
    check = ['KVGT', 'KLAS', 'KHND', 'KLSV', 'KBVU', '36K', '0L7', '06C',
             'KATL', 'KORD', 'KCRQ', 'KBOS', 'KRHV']
    print('\n--- validation spot check ---')
    idx = {(a.get('icao') or '').strip(): a for a in airports}
    for k in check:
        a = idx.get(k)
        if a:
            city = f"  ({a.get('city','')}, {a.get('state','')})" if add_city else ''
            print(f"  {k:6} -> {a['name']!r}{city}")
        else:
            print(f"  {k:6} -> not in airports.json")


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--nasr', required=True)
    ap.add_argument('--airports', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--title-expand', action='store_true')
    ap.add_argument('--no-city', action='store_true')
    args = ap.parse_args()
    merge(args.nasr, args.airports, args.out,
          expand=args.title_expand, add_city=not args.no_city)
