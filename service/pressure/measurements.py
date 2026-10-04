import csv, io, math
from fastapi import APIRouter, Depends, Query, Response
from fastapi.responses import StreamingResponse
from .auth import authenticated, database
from .common import *
from .models import SessionStart, Batch, Complete, ID, Time
router=APIRouter(prefix='/api/v1')

def session_value(r):
    return {'id':r['id'],**obj(r['start']),'status':r['status'],'ended_at':None,'expected_samples_by_device':{},'gaps':[],**(obj(r['completion']) if r['completion'] else {})}
def check_ownership(db,s,account):
    for d in s['devices']:
        actual=owned(db,'devices',d['device_id'],account)
        if actual['ownership']!=d['ownership_id']: fail(409,'ownership_changed')
def interpolate(a,b,at):
    ta,tb=epoch(a['captured_at']),epoch(b['captured_at'])
    if not ta<=at<=tb or not 0<tb-ta<=2.00001 or a['segment_id']!=b['segment_id'] or max(a['accuracy_m'],b['accuracy_m'])>10: return None
    f=(at-ta)/(tb-ta)
    def mix(k): return a[k]+(b[k]-a[k])*f
    return {'latitude':mix('latitude'),'longitude':mix('longitude'),'accuracy_m':max(a['accuracy_m'],b['accuracy_m']),'speed_mps':mix('speed_mps') if a.get('speed_mps') is not None and b.get('speed_mps') is not None else None,'fix_before_id':a['id'],'fix_after_id':b['id'],'method':'interpolated'}
@router.put('/sessions/{id}')
def start(id:ID,body:SessionStart,response:Response,a=Depends(authenticated),db=Depends(database, scope="function")):
    s=obj(dump(body)); old=one(db,'SELECT * FROM sessions WHERE id=?',(id,))
    if old:
        if old['account']!=a['account']: fail(404,'not_found')
        if old['start']!=dump(s): fail(409,'session_conflict')
        return session_value(old)
    if len({d['device_id'] for d in s['devices']})!=2 or {d['role'] for d in s['devices']}!={'A','B'}: fail(422,'invalid_channels')
    check_ownership(db,s,a['account'])
    rig=one(db,'SELECT * FROM rigs WHERE id=?',(s['rig_id'],))
    if rig and rig['account']!=a['account']: fail(404,'not_found')
    if body.started_at.timestamp()>now()+300: fail(422,'future_session')
    db.execute('INSERT INTO sessions(id,account,start,started,rig) VALUES(?,?,?,?,?)',(id,a['account'],dump(s),body.started_at.timestamp(),s['rig_id']))
    response.status_code=201
    return session_value(owned(db,'sessions',id,a['account']))

def record(db,kind,key,account,session):
    r=one(db,'SELECT data FROM records WHERE kind=? AND key=? AND account=? AND session=?',(kind,key,account,session))
    if not r: fail(422,'missing_reference')
    return obj(r['data'])
def add_record(db,kind,key,data,account,session,role=None):
    text=dump(data); old=one(db,'SELECT * FROM records WHERE kind=? AND key=?',(kind,key))
    if old:
        if old['account']!=account or old['session']!=session or old['data']!=text: fail(409,'record_conflict')
        return False
    loc=data.get('location'); flags=data.get('flags',[])
    eligible=int(loc is not None and data.get('pressure_pa') is not None and not {'sensor_error','pressure_out_of_range','time_uncertain'}&set(flags))
    db.execute('INSERT INTO records(account,session,kind,key,data,device,at,role,pa,lat,lon,eligible,speed) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)', (account,session,kind,key,text,data.get('device_id'),epoch(data['captured_at']) if 'captured_at' in data else None,role,data.get('pressure_pa'),loc['latitude'] if loc else None,loc['longitude'] if loc else None,eligible,loc.get('speed_mps') if loc else None))
    return True
@router.post('/sessions/{id}/batches')
def batch(id:ID,body:Batch,a=Depends(authenticated),db=Depends(database, scope="function")):
    row=owned(db,'sessions',id,a['account']); s=obj(row['start']); check_ownership(db,s,a['account'])
    b=obj(dump(body)); hashed=digest(dump(b))
    previous=one(db,'SELECT * FROM batches WHERE id=?',(body.batch_id,))
    if previous:
        if previous['account']!=a['account'] or previous['session']!=id or previous['hash']!=hashed: fail(409,'batch_conflict')
        return obj(previous['receipt'])
    if row['status']!='recording': fail(409,'session_closed')
    if shutil_free()<64*1024*1024: fail(503,'storage_low','Kevés szervertárhely; a mérés maradjon az appban.')
    snapshots={d['device_id']:d for d in s['devices']}; inserted=duplicates=0
    def add(kind,key,data,role=None):
        nonlocal inserted,duplicates
        if add_record(db,kind,key,data,a['account'],id,role): inserted+=1
        else: duplicates+=1
    for seg in b['time_segments']:
        if seg['device_id'] and seg['device_id'] not in snapshots: fail(422,'wrong_device')
        add('segment',seg['id'],seg)
    for fix in b['gps_fixes']:
        seg=record(db,'segment',fix['segment_id'],a['account'],id)
        if seg['device_id'] is not None: fail(422,'gps_segment_required')
        if epoch(fix['captured_at'])>now()+300: fail(422,'future_fix')
        add('fix',fix['id'],fix)
    for sample in b['samples']:
        dev=sample['device_id']; at=epoch(sample['captured_at'])
        if dev not in snapshots: fail(422,'wrong_device')
        seg=record(db,'segment',sample['time_segment_id'],a['account'],id)
        if seg['device_id']!=dev or seg['boot_id']!=sample['boot_id']: fail(422,'time_segment_mismatch')
        expected=epoch(seg['utc_anchor'])+(sample['uptime_ms']-seg['uptime_anchor_ms'])/1000
        if abs(at-expected)>0.002 or at<row['started']-300 or at>now()+300: fail(422,'sample_time_mismatch')
        loc=sample['location']
        if loc is not None:
            before=record(db,'fix',loc['fix_before_id'],a['account'],id); after=record(db,'fix',loc['fix_after_id'],a['account'],id)
            gpsseg=record(db,'segment',before['segment_id'],a['account'],id)
            expectedloc=interpolate(before,after,at)
            if not s['gps_enabled'] or seg['uncertainty_ms']>100 or gpsseg['uncertainty_ms']>100 or 'time_uncertain' in sample['flags'] or not expectedloc: fail(422,'invalid_location')
            for key,tolerance in [('latitude',0.0000001),('longitude',0.0000001),('accuracy_m',0.0001),('speed_mps',0.0001)]:
                x,y=loc.get(key),expectedloc.get(key)
                if (x is None)!=(y is None) or (x is not None and abs(x-y)>tolerance): fail(422,'location_mismatch')
        elif not set(sample['flags'])&{'gps_missing','gps_disabled','gps_inaccurate','time_uncertain'}: fail(422,'location_flag_required')
        if seg['uncertainty_ms']>100 and 'time_uncertain' not in sample['flags']: fail(422,'uncertainty_flag_required')
        add('sample',f"{dev}/{sample['boot_id']}/{sample['seq']}",sample,snapshots[dev]['role'])
    result={'batch_id':body.batch_id,'inserted':inserted,'duplicates':duplicates}
    db.execute('INSERT INTO batches VALUES(?,?,?,?,?)',(body.batch_id,a['account'],id,hashed,dump(result)))
    return result

def shutil_free():
    import shutil
    return shutil.disk_usage(str(Path(DB).parent)).free
@router.post('/sessions/{id}/complete')
def complete(id:ID,body:Complete,a=Depends(authenticated),db=Depends(database, scope="function")):
    s=owned(db,'sessions',id,a['account']); check_ownership(db,obj(s['start']),a['account'])
    text=dump(body)
    if s['completion']:
        if s['completion']!=text: fail(409,'completion_conflict')
        return session_value(s)
    counts={d['device_id']:0 for d in obj(s['start'])['devices']}
    counts.update({r['device']:r['n'] for r in db.execute("SELECT device,count(*) n FROM records WHERE account=? AND session=? AND kind='sample' GROUP BY device",(a['account'],id))})
    if counts!={k:body.expected_samples_by_device.get(k,0) for k in counts} or set(body.expected_samples_by_device)-set(counts): fail(409,'sample_count_mismatch')
    last=one(db,"SELECT MAX(at) t FROM records WHERE account=? AND session=? AND kind='sample'",(a['account'],id))['t']
    if body.ended_at.timestamp()<max(s['started'],last or s['started']) or body.ended_at.timestamp()>now()+300: fail(422,'invalid_end_time')
    for gap in body.gaps:
        if gap.device_id not in counts or gap.ended_at<gap.started_at: fail(422,'invalid_gap')
    db.execute('UPDATE sessions SET status=?,completion=? WHERE id=?',(body.status,text,id))
    return session_value(owned(db,'sessions',id,a['account']))

def filters(account,from_,to,rig_ids=None,device_ids=None,session_ids=None):
    where=['s.account=?']; args=[account]
    if from_ is not None: where.append('s.started>=?'); args.append(from_.timestamp())
    if to is not None: where.append('s.started<=?'); args.append(to.timestamp())
    for field,raw in [('s.rig',rig_ids),('s.id',session_ids)]:
        if raw:
            values=raw.split(',')
            if len(values)>50: fail(422,'too_many_filters')
            where.append(f"{field} IN ({','.join('?' for _ in values)})"); args+=values
    if device_ids:
        values=device_ids.split(',')
        if len(values)>50: fail(422,'too_many_filters')
        where.append(f"EXISTS (SELECT 1 FROM json_each(s.start,'$.devices') d WHERE json_extract(d.value,'$.device_id') IN ({','.join('?' for _ in values)}))"); args+=values
    return where,args
@router.get('/sessions')
def sessions(from_:Time|None=Query(None,alias='from'),to:Time|None=None,rig_ids:str|None=None,device_ids:str|None=None,cursor:str|None=None,limit:int=Query(100,ge=1,le=1000),a=Depends(authenticated),db=Depends(database, scope="function")):
    where,args=filters(a['account'],from_,to,rig_ids,device_ids)
    if cursor:
        r=owned(db,'sessions',cursor,a['account']); where.append('(s.started<? OR (s.started=? AND s.id>?))'); args.extend([r['started'],r['started'],r['id']])
    rows=db.execute('SELECT s.* FROM sessions s WHERE '+' AND '.join(where)+' ORDER BY s.started DESC,s.id LIMIT ?',args+[limit+1]).fetchall()
    return {'items':[session_value(s) for s in rows[:limit]],'next_cursor':rows[limit-1]['id'] if len(rows)>limit else None}
@router.get('/sessions/{id}')
def get_session(id:ID,a=Depends(authenticated),db=Depends(database, scope="function")):
    s=owned(db,'sessions',id,a['account']); result=session_value(s)
    result['sample_counts']={r['device']:r['n'] for r in db.execute("SELECT device,count(*) n FROM records WHERE account=? AND session=? AND kind='sample' GROUP BY device",(a['account'],id))}
    return result

def read_records(db,account,id,kind,limit,cursor,from_,to,device):
    owned(db,'sessions',id,account)
    where=['account=?','session=?','kind=?']; args=[account,id,kind]
    if cursor:
        try: cursor=int(cursor)
        except ValueError: fail(422,'invalid_cursor')
        r=one(db,'SELECT at,id FROM records WHERE id=? AND account=? AND session=? AND kind=?',(cursor,account,id,kind))
        if not r: fail(422,'invalid_cursor')
        where.append('(at>? OR (at=? AND id>?))'); args += [r['at'],r['at'],r['id']]
    if from_ is not None: where.append('at>=?'); args.append(from_.timestamp())
    if to is not None: where.append('at<=?'); args.append(to.timestamp())
    if device: where.append('device=?'); args.append(device)
    rows=db.execute('SELECT id,data FROM records WHERE '+' AND '.join(where)+' ORDER BY at,id LIMIT ?',args+[limit+1]).fetchall()
    return {'items':[obj(r['data']) for r in rows[:limit]],'next_cursor':str(rows[limit-1]['id']) if len(rows)>limit else None}
@router.get('/sessions/{id}/samples')
def samples(id:ID,limit:int=Query(100,ge=1,le=1000),cursor:str|None=None,from_:Time|None=Query(None,alias='from'),to:Time|None=None,device_id:str|None=None,a=Depends(authenticated),db=Depends(database, scope="function")):
    return read_records(db,a['account'],id,'sample',limit,cursor,from_,to,device_id)
@router.get('/sessions/{id}/track')
def track(id:ID,limit:int=Query(100,ge=1,le=1000),cursor:str|None=None,a=Depends(authenticated),db=Depends(database, scope="function")):
    return read_records(db,a['account'],id,'fix',limit,cursor,None,None,None)
@router.get('/sessions/{id}/series')
def series(id:ID,from_:Time=Query(alias='from'),to:Time=Query(),bucket_ms:int=Query(1000,ge=100,le=86400000),device_id:str|None=None,a=Depends(authenticated),db=Depends(database, scope="function")):
    owned(db,'sessions',id,a['account'])
    if to<=from_ or (to-from_).total_seconds()*1000/bucket_ms>2500: fail(422,'too_many_points')
    rows=db.execute("SELECT device,CAST(at*1000/? AS INTEGER)*? AS bucket,AVG(pa) mean,MIN(pa) min,MAX(pa) max,COUNT(pa) n FROM records WHERE account=? AND session=? AND kind='sample' AND at>=? AND at<=? AND (? IS NULL OR device=?) GROUP BY device,bucket ORDER BY bucket,device LIMIT 5001",(bucket_ms,bucket_ms,a['account'],id,from_.timestamp(),to.timestamp(),device_id,device_id)).fetchall()
    if len(rows)>5000: fail(422,'too_many_points')
    return {'items':[{'device_id':r['device'],'captured_at':iso(r['bucket']/1000),'mean_pa':r['mean'],'min_pa':r['min'],'max_pa':r['max'],'sample_count':r['n']} for r in rows]}
@router.get('/sessions/{id}/export.csv')
def export(id:ID,a=Depends(authenticated),db=Depends(database, scope="function")):
    owned(db,'sessions',id,a['account']); account=a['account']
    def stream():
        out=io.StringIO(); writer=csv.writer(out)
        fields=['device_id','boot_id','seq','captured_at','uptime_ms','raw_count','pressure_pa','battery_mv','soc_pct','latitude','longitude','accuracy_m','speed_mps','flags']
        writer.writerow(fields); yield out.getvalue(); out.seek(0); out.truncate(0)
        cursor=None
        while True:
            with connect() as conn: page=read_records(conn,account,id,'sample',1000,cursor,None,None,None)
            for s in page['items']:
                s={**s,**(s['location'] or {}),'flags':'|'.join(s['flags'])}
                writer.writerow([s.get(k) for k in fields])
            yield out.getvalue(); out.seek(0); out.truncate(0)
            cursor=page['next_cursor']
            if not cursor: break
    return StreamingResponse(stream(),media_type='text/csv',headers={'Content-Disposition':f'attachment; filename="pressure-{id}.csv"'})
