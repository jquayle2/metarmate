"""Phase 1.4: anonymous MADIS access probe (no credentials).

One pass over a fixed URL list. For each URL it records the UTC timestamp, HTTP status,
bytes, elapsed time, attempts and a login/forbidden hint. Every call goes through
common.get (20 s timeout, at most 2 retries). IPv4 is forced: madis.ncep.noaa.gov
completed TLS over IPv6 and then never responded (see findings Q1).

URLs marked "guess" are paths not taken from MADIS docs. A 404 there means only that
the guess was wrong.

Writes logs/access_probe_<UTC>.csv and prints a table.
"""
import csv
import ftplib
import os
import socket
from datetime import datetime, timezone

import urllib3.util.connection

from common import TIMEOUT_S, get, iso

urllib3.util.connection.allowed_gai_family = lambda: socket.AF_INET

HTTP_TARGETS = [
    ("sample dir (documented)", "https://madis.ncep.noaa.gov/sample_data/software/sampledata/LDAD/OMO/netCDF/"),
    ("OMO dataset page", "https://madis.ncep.noaa.gov/madis_OMO.shtml"),
    ("OMO variable list", "https://madis.ncep.noaa.gov/sfc_OMO_variable_list.shtml"),
    ("distribution home", "https://madis-data.ncep.noaa.gov/"),
    ("public data root (guess)", "https://madis-data.ncep.noaa.gov/madisPublic1/data/"),
    ("public OMO/hfmetar netCDF (guess)", "https://madis-data.ncep.noaa.gov/madisPublic1/data/LDAD/hfmetar/netCDF/"),
    ("research data root (guess)", "https://madis-data.ncep.noaa.gov/madisResearch/data/"),
    ("public Text/XML viewer (guess)", "https://madis-data.ncep.noaa.gov/madisPublic/cgi-bin/madisXmlPublicDir"),
]
FTP_HOST = "madis-data.ncep.noaa.gov"


def hint(r):
    body = r.text[:4000].lower() if r.content else ""
    if r.status_code in (401, 403):
        return "forbidden/auth"
    if any(w in body for w in ("password", "login", "sign in", "username")):
        return "login form in body"
    if "index of" in body:
        return "directory index"
    return ""


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(os.path.join(here, "logs"), exist_ok=True)
    start = datetime.now(timezone.utc)
    path = os.path.join(here, "logs", f"access_probe_{start:%Y%m%dT%H%MZ}.csv")
    rows = []
    for label, url in HTTP_TARGETS:
        t = datetime.now(timezone.utc)
        try:
            r, done, elapsed, attempts = get(url)
            row = [iso(t), label, url, r.status_code, len(r.content), round(elapsed, 2), attempts,
                   r.headers.get("WWW-Authenticate", "") or hint(r), r.url if r.url != url else ""]
        except Exception as e:
            row = [iso(t), label, url, "ERR", 0, "", 3, repr(e)[:160], ""]
        rows.append(row)
        print(" | ".join(map(str, row)))

    t = datetime.now(timezone.utc)
    try:
        with ftplib.FTP(FTP_HOST, timeout=TIMEOUT_S) as ftp:
            welcome = ftp.getwelcome()
            try:
                ftp.login()  # anonymous
                result = "anonymous login OK; " + " ".join(ftp.nlst()[:10])
            except ftplib.error_perm as e:
                result = f"anonymous login refused: {e}"
        row = [iso(t), "FTP anonymous", f"ftp://{FTP_HOST}/", "FTP", 0, "", 1, result[:200], welcome[:120]]
    except Exception as e:
        row = [iso(t), "FTP anonymous", f"ftp://{FTP_HOST}/", "ERR", 0, "", 1, repr(e)[:160], ""]
    rows.append(row)
    print(" | ".join(map(str, row)))

    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["time", "label", "url", "status", "bytes", "elapsed_s", "attempts", "note", "final_url_or_banner"])
        w.writerows(rows)
    print(f"written: {path}")


if __name__ == "__main__":
    main()
