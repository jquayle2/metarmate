"""Shared bits for the MADIS / 5-min ASOS research spike.

Station list, HTTP helper with fetch timing, and unit conversions. All conversions
are exact factors; anything compared against a METAR is compared against the raw
METAR text, never "corrected" to agree.
"""
import time
from datetime import datetime, timezone

import requests

USER_AGENT = "MetarMate-research (jquayle2 on GitHub)"

# ASOS/AWOS type from FAA NASR AWOS.csv (28-day subscription effective 2026-06-11).
# dist_nm is great-circle from KVGT's NASR sensor position.
STATIONS = [
    {"icao": "KVGT", "type": "ASOS",     "dist_nm": 0,   "ref_only": False},
    {"icao": "KLAS", "type": "ASOS",     "dist_nm": 9,   "ref_only": False},
    {"icao": "KHND", "type": "AWOS-3PT", "dist_nm": 15,  "ref_only": False},
    {"icao": "KBVU", "type": "AWOS-3",   "dist_nm": 23,  "ref_only": False},
    {"icao": "KIFP", "type": "AWOS-3PT", "dist_nm": 71,  "ref_only": False},
    {"icao": "KIGM", "type": "ASOS",     "dist_nm": 84,  "ref_only": False},
    {"icao": "KEED", "type": "ASOS",     "dist_nm": 91,  "ref_only": False},
    # Out-of-radius references (named in the handoff, well beyond 100 nm).
    {"icao": "KPHX", "type": "ASOS",     "dist_nm": 229, "ref_only": True},
    {"icao": "KSLC", "type": "ASOS",     "dist_nm": 313, "ref_only": True},
]
ICAOS = [s["icao"] for s in STATIONS]

_session = requests.Session()
_session.headers["User-Agent"] = USER_AGENT


def get(url, params=None, headers=None, timeout=30):
    """GET with timing. Returns (response, fetched_at_utc, elapsed_s)."""
    t0 = time.monotonic()
    r = _session.get(url, params=params, headers=headers, timeout=timeout)
    return r, datetime.now(timezone.utc), time.monotonic() - t0


# --- unit conversions (exact definitions) ---
def kmh_to_kt(v):  return None if v is None else v / 1.852
def ms_to_kt(v):   return None if v is None else v * 3600 / 1852
def m_to_sm(v):    return None if v is None else v / 1609.344
def m_to_ft(v):    return None if v is None else v / 0.3048
def pa_to_inhg(v): return None if v is None else v / 3386.389
def hpa_to_inhg(v): return None if v is None else v * 100 / 3386.389
def k_to_c(v):     return None if v is None else v - 273.15


def iso(dt):
    return None if dt is None else dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
