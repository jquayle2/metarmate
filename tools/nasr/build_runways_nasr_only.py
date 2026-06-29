import csv, json

BASE='/Users/jquayle/Downloads/28DaySubscription_Effective_2026-06-11/CSV_Data/nasr_csv/'
CUR='/Users/jquayle/code/xcode/MetarMate/MetarMate/Resources/runways.json'

SURF_MAP={'ASPH':'ASP','CONC':'CON','TURF':'TURF','GRVL':'GVL','DIRT':'DIRT',
 'GRASS':'GRS','WATER':'WATER','SNOW':'SNOW','ICE':'ICE','SAND':'SAND'}
def surf(code):
    c=(code or '').upper().split('-')[0].strip()
    return SURF_MAP.get(c, c[:4] if c else 'UNK')

icao={}; lid={}
for r in csv.DictReader(open(BASE+'APT_BASE.csv')):
    if r['SITE_TYPE_CODE']=='A':
        icao[r['SITE_NO']]=r['ICAO_ID'].strip()
        lid[r['SITE_NO']]=r['ARPT_ID']

dims={}
for r in csv.DictReader(open(BASE+'APT_RWY.csv')):
    dims[(r['SITE_NO'],r['RWY_ID'])]={'len':r['RWY_LEN'],'wid':r['RWY_WIDTH'],'sfc':surf(r['SURFACE_TYPE_CODE'])}

ends={}
for r in csv.DictReader(open(BASE+'APT_RWY_END.csv')):
    ends.setdefault((r['SITE_NO'],r['RWY_ID']),{})[r['RWY_END_ID']]=r['TRUE_ALIGNMENT']

def keyfor(site):
    ic=icao.get(site,'')
    return ic if ic else lid.get(site,'')

out={}; skipped=0
for (site,rid),d in dims.items():
    e=ends.get((site,rid),{})
    parts=rid.split('/')
    if len(parts)!=2: continue
    le,he=parts
    leh=e.get(le,''); heh=e.get(he,'')
    if not leh or not heh: skipped+=1; continue
    try:
        lehi=int(round(float(leh))); hehi=int(round(float(heh)))
    except: skipped+=1; continue
    k=keyfor(site)
    if not k: continue
    try: L=int(d['len'])
    except: L=0
    try: W=int(d['wid'])
    except: W=0
    out.setdefault(k,[]).append({'le':le,'leHdg':lehi,'he':he,'heHdg':hehi,'len':L,'wid':W,'sfc':d['sfc']})

print('NASR-built airports:',len(out),' skipped runways w/o heading:',skipped)
cur=json.load(open(CUR))
curk=set(cur); newk=set(out)
print('current:',len(curk),' new:',len(newk))
print('both:',len(curk&newk),' lost(only current):',len(curk-newk),' gained(only new):',len(newk-curk))

diffs=[]
for k in (curk&newk):
    cm={r['le']:r['leHdg'] for r in cur[k]}; cm.update({r['he']:r['heHdg'] for r in cur[k]})
    nm={r['le']:r['leHdg'] for r in out[k]}; nm.update({r['he']:r['heHdg'] for r in out[k]})
    for end,h in nm.items():
        if end in cm:
            diffs.append(abs((h-cm[end]+180)%360-180))
big=[d for d in diffs if d>2]
print('ends compared:',len(diffs),' differ >2deg:',len(big),' max:',max(diffs) if diffs else 0)
print('KVGT:',json.dumps(out.get('KVGT')))

json.dump(out, open('/Users/jquayle/Downloads/runways_nasr.json','w'), separators=(',',':'))
print('wrote /Users/jquayle/Downloads/runways_nasr.json')
