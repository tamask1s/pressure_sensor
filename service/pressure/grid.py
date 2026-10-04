from bisect import bisect_right
from collections import defaultdict
import math
from typing import Literal
from pyproj import Transformer
from fastapi import APIRouter, Depends, Query
from .auth import authenticated, database
from .common import *
from .measurements import filters, interpolate
from .models import Time
router=APIRouter(prefix='/api/v1')

def aggregate(rows,fixes,srid,size,bbox):
    project=Transformer.from_crs(4326,srid,always_xy=True); inverse=Transformer.from_crs(srid,4326,always_xy=True)
    seconds=defaultdict(list)
    for r in rows: seconds[(r['session'],r['second'])].append(r)
    times={s:[epoch(f['captured_at']) for f in fs] for s,fs in fixes.items()}
    per_session={}
    for (session,sec),channels in seconds.items():
        fs=fixes.get(session,[]); ts=times.get(session,[]); at=sec+.5; i=bisect_right(ts,at)
        if i==len(ts) and ts and ts[-1]==at: i-=1
        if i==0 or i==len(ts): continue
        loc=interpolate(fs[i-1],fs[i],at)
        if not loc: continue
        x,y=project.transform(loc['longitude'],loc['latitude']); ix,iy=math.floor(x/size),math.floor(y/size)
        lon,lat=inverse.transform((ix+.5)*size,(iy+.5)*size)
        # Include cells intersecting the viewport; never change their averages at a viewport edge.
        corners=[inverse.transform(px*size,py*size) for px,py in [(ix,iy),(ix+1,iy),(ix+1,iy+1),(ix,iy+1),(ix,iy)]]
        west,south,east,north=bbox
        if max(p[0] for p in corners)<west or min(p[0] for p in corners)>east or max(p[1] for p in corners)<south or min(p[1] for p in corners)>north: continue
        c=per_session.setdefault((session,ix,iy),{'sum':0,'seconds':0,'sample_count':0,'channels':set(),'min_pa':float('inf'),'max_pa':-float('inf'),'partial_channel_seconds':0,'geometry':{'type':'Polygon','coordinates':[corners]}})
        c['sum']+=sum(r['mean'] for r in channels)/len(channels); c['seconds']+=1
        c['sample_count']+=sum(r['n'] for r in channels); c['channels'].update(r['role'] for r in channels)
        c['min_pa']=min(c['min_pa'],*(r['min'] for r in channels)); c['max_pa']=max(c['max_pa'],*(r['max'] for r in channels))
        c['partial_channel_seconds']+=int(len(channels)<2)
        if len(per_session)>100000: fail(422,'map_range_too_large')
    cells={}
    for (session,ix,iy),p in per_session.items():
        c=cells.setdefault((ix,iy),{'ix':ix,'iy':iy,'geometry':p['geometry'],'sum':0,'session_count':0,'sample_count':0,'channels':set(),'min_pa':float('inf'),'max_pa':-float('inf'),'partial_channel_seconds':0})
        c['sum']+=p['sum']/p['seconds']; c['session_count']+=1; c['channels'].update(p['channels'])
        for k in ['sample_count','partial_channel_seconds']: c[k]+=p[k]
        c['min_pa']=min(c['min_pa'],p['min_pa']); c['max_pa']=max(c['max_pa'],p['max_pa'])
    if len(cells)>5000: fail(422,'grid_too_fine','Válassz nagyobb cellaméretet vagy kisebb területet.')
    result=[]
    for key in sorted(cells):
        c=cells[key]; c['mean_pa']=c.pop('sum')/c['session_count']; c['channel_count']=len(c.pop('channels')); result.append(c)
    return result
@router.get('/map/cells')
def cells(from_:Time=Query(alias='from'),to:Time=Query(),bbox:str=Query(),grid_srid:int=32634,cell_m:int=10,layer:Literal['combined','A','B']='combined',moving_only:bool=True,rig_ids:str|None=None,device_ids:str|None=None,session_ids:str|None=None,a=Depends(authenticated),db=Depends(database, scope="function")):
    if not (32601<=grid_srid<=32660 or 32701<=grid_srid<=32760) or cell_m not in [10,20,50,100,250,500,1000]: fail(422,'invalid_grid')
    try:
        box=[float(v) for v in bbox.split(',')]; west,south,east,north=box
    except ValueError: fail(422,'invalid_bbox')
    if not all(math.isfinite(v) for v in box) or not (-180<=west<east<=180 and -80<=south<north<=84) or (east-west)*(north-south)>100: fail(422,'invalid_bbox')
    if to<=from_ or (to-from_).days>366: fail(422,'invalid_time_range')
    where,args=filters(a['account'],None,None,rig_ids,None,session_ids)
    where+=['r.account=s.account','r.session=s.id',"r.kind='sample'",'r.at>=?','r.at<=?']; args += [from_.timestamp(),to.timestamp()]
    if device_ids:
        ds=device_ids.split(',')
        if len(ds)>50: fail(422,'too_many_filters')
        where.append('r.device IN ('+','.join('?' for _ in ds)+')'); args+=ds
    if layer!='combined': where.append('r.role=?'); args.append(layer)
    source=' FROM records r JOIN sessions s ON r.session=s.id WHERE '+' AND '.join(where)
    good='r.eligible=1'+(' AND r.speed>=0.5' if moving_only else '')
    quality=one(db,'SELECT COALESCE(SUM(r.lat IS NULL),0) missing,COALESCE(SUM(r.lat IS NOT NULL AND NOT ('+good.replace('r.speed>=0.5','COALESCE(r.speed,-1)>=0.5')+')),0) excluded'+source,args)
    rows=db.execute('SELECT r.session,CAST(r.at AS INTEGER) second,r.role,AVG(r.pa) mean,MIN(r.pa) min,MAX(r.pa) max,COUNT(*) n'+source+' AND '+good+' GROUP BY r.session,second,r.role LIMIT 100001',args).fetchall()
    if len(rows)>100000: fail(422,'map_range_too_large','Szűkítsd az időszakot.')
    fixes={}
    for session in {r['session'] for r in rows}:
        fs=db.execute("SELECT data FROM records WHERE account=? AND session=? AND kind='fix' AND at>=? AND at<=? ORDER BY at,id LIMIT 100001",(a['account'],session,from_.timestamp()-2,to.timestamp()+2)).fetchall()
        if len(fs)>100000: fail(422,'map_range_too_large')
        fixes[session]=[obj(f['data']) for f in fs]
    return {'algorithm':'pressure-grid-v1','grid_srid':grid_srid,'cell_m':cell_m,'scale':{'min_pa':0,'max_pa':20000000},'cells':aggregate(rows,fixes,grid_srid,cell_m,box),'quality':{'excluded_samples':quality['excluded'],'missing_location_samples':quality['missing']}}
