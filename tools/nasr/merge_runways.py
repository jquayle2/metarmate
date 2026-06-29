#!/usr/bin/env python3
"""
merge_runways.py - Rebuild MetarMate's runways.json from FAA NASR + OurAirports base.

WHY: METAR/TAF wind is TRUE north. Runway crosswind math converts wind TRUE->magnetic
via WMM. The runway heading must therefore also be a TRUE heading (it gets converted the
same way in RunwayService). This script produces a runways.json of uniformly TRUE headings,
preferring FAA-surveyed values where they exist.

HEADING SOURCE FALLBACK (per runway end):
  1. NASR TRUE_ALIGNMENT  (FAA surveyed, authoritative)   -- used where present
  2. OurAirports computed heading (existing runways.json)  -- full-coverage fallback
  3. designator x10                                        -- last resort (~never fires)
Heliport ends (H-prefixed) are skipped entirely.

NASR refreshes every 28 days. To refresh:
  1. Download the current 28-Day NASR Subscription CSV from the FAA NFDC site.
  2. Unzip so the *.csv files (APT_BASE.csv, APT_RWY.csv, APT_RWY_END.csv) sit in one folder.
  3. python3 merge_runways.py --nasr /path/to/nasr_csv --current /path/to/current/runways.json --out /path/to/new/runways.json
  4. Review the printed validation (diagram checks should match within ~2 deg; coverage == current).
  5. Copy the new file over MetarMate/Resources/runways.json and rebuild.

VALIDATION: computed magnetic (true - declination) is checked against published FAA airport
diagram magnetic headings for KVGT/KLAS/KSEA/KBOS (variation range 16E..15W). All should match
within ~2 deg. KSEA and KBOS (the extremes) should be exact.
"""
import csv, json, argparse, os

SURF_MAP={'ASPH':'ASP','CONC':'CON','TURF':'TURF','GRVL':'GVL','DIRT':'DIRT',
 'GRASS':'GRS','WATER':'WATER','SNOW':'SNOW','ICE':'ICE','SAND':'SAND'}
def surf(code):
    c=(code or '').upper().split('-')[0].strip()
    return SURF_MAP.get(c, c[:4] if c else 'UNK')

def build(nasr_dir, current_path, out_path):
    B=lambda f: os.path.join(nasr_dir,f)
    icao={}; lid={}
    for r in csv.DictReader(open(B('APT_BASE.csv'))):
        if r['SITE_TYPE_CODE']=='A':
            icao[r['SITE_NO']]=r['ICAO_ID'].strip(); lid[r['SITE_NO']]=r['ARPT_ID']
    keyfor=lambda s: icao.get(s,'') or lid.get(s,'')

    nasr_hdg={}
    for r in csv.DictReader(open(B('APT_RWY_END.csv'))):
        ta=r['TRUE_ALIGNMENT'].strip(); end=r['RWY_END_ID'].strip()
        if not ta or end.startswith('H'): continue
        try: nasr_hdg[(keyfor(r['SITE_NO']),end)]=int(round(float(ta)))
        except: pass
    print('NASR surveyed headings:',len(nasr_hdg))

    cur=json.load(open(current_path))
    def x10(ident):
        n=''.join(c for c in ident if c.isdigit())
        return (int(n)%36)*10 if n else None

    from_nasr=corrected=from_oa=from_x10=0
    merged={}
    for key,rwys in cur.items():
        newrwys=[]
        for rw in rwys:
            rw=dict(rw); skip=False
            for endf,hf in (('le','leHdg'),('he','heHdg')):
                end=rw[endf]
                if end.startswith('H'): skip=True; break
                n=nasr_hdg.get((key,end))
                if n is not None:
                    if n!=rw.get(hf): corrected+=1
                    rw[hf]=n; from_nasr+=1
                elif rw.get(hf) not in (None,'',0): from_oa+=1
                else:
                    xv=x10(end)
                    if xv is not None: rw[hf]=xv; from_x10+=1
            if not skip: newrwys.append(rw)
        if newrwys: merged[key]=newrwys

    # reciprocal repair: if one end is NASR-authoritative and the pair isn't ~180 apart,
    # set the opposite end to the exact reciprocal.
    repaired=0
    for key,rl in merged.items():
        for rw in rl:
            le_n=(key,rw['le']) in nasr_hdg; he_n=(key,rw['he']) in nasr_hdg
            off=abs(abs(rw['leHdg']-rw['heHdg'])%360-180)
            if off>5:
                if le_n and not he_n: rw['heHdg']=(rw['leHdg']+180)%360 or 360; repaired+=1
                elif he_n and not le_n: rw['leHdg']=(rw['heHdg']+180)%360 or 360; repaired+=1

    print(f'merged airports:{len(merged)} ends_from_NASR:{from_nasr} corrected:{corrected} '
          f'oa_fallback:{from_oa} x10:{from_x10} reciprocal_repairs:{repaired}')
    json.dump(merged,open(out_path,'w'),separators=(',',':'))
    print('wrote',out_path)

    checks=[('KVGT',11.7,{'07':'074','25':'254'}),('KLAS',11.8,{'08R':'079','26R':'259'}),
            ('KSEA',16.0,{'16L':'164','34R':'344'}),('KBOS',-15.0,{'04R':'035','22L':'215'})]
    print('--- diagram validation (computed mag vs FAA diagram) ---')
    for k,dec,exp in checks:
        hd={}
        for rw in merged.get(k,[]): hd[rw['le']]=rw['leHdg']; hd[rw['he']]=rw['heHdg']
        for end,dia in exp.items():
            if end in hd: print(f'  {k} {end}: true {hd[end]} -> mag {round((hd[end]-dec)%360)} (diagram {dia})')
            else: print(f'  {k} {end}: NOT FOUND')

if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--nasr',required=True,help='folder with APT_BASE/APT_RWY/APT_RWY_END .csv')
    ap.add_argument('--current',required=True,help='current runways.json (OurAirports base)')
    ap.add_argument('--out',required=True,help='output path for merged runways.json')
    a=ap.parse_args()
    build(a.nasr,a.current,a.out)
