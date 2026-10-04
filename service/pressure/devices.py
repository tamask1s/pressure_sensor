import hmac
from fastapi import APIRouter, Depends, Query
from .auth import authenticated, database
from .common import *
from .security import claim_proof
from .models import Challenge, Proof, Rename, Rig, Archive, Presence, ID
router=APIRouter(prefix='/api/v1')

def state(db,d):
    p=one(db,'SELECT p.*,l.expires FROM presence p LEFT JOIN leases l ON l.id=p.lease WHERE p.device=? AND p.account=?',(d['id'],d['account']))
    if not p: return None
    data=obj(p['data']); age=max(0,int((now()-p['observed'])*1000)); online=(p['expires'] or 0)>now() and age<30000
    fresh=online and data['ble_connected'] and data['sensor_ok'] and data['sample_age_ms'] is not None and data['sample_age_ms']<=2000
    last=one(db,"SELECT MAX(at) AS t FROM records WHERE account=? AND kind='sample' AND device=?",(d['account'],d['id']))['t']
    return {**data,'state':'fresh' if fresh else 'collector_online_device_stale' if online else 'last_seen','observed_at':iso(p['observed']),'state_age_ms':age,'last_seen_at':iso(p['observed']),'last_measurement_at':iso(last) if last is not None else None}
def device(db,d):
    meta=obj(d['metadata']); m=one(db,'SELECT rig FROM members WHERE device=? AND account=?',(d['id'],d['account']))
    return {'id':d['id'],'name':d['name'],'ownership_id':d['ownership'],**meta,'rig_id':m['rig'] if m else None,'presence':state(db,d)}
def page(rows,limit,convert):
    return {'items':[convert(r) for r in rows[:limit]],'next_cursor':rows[limit-1]['id'] if len(rows)>limit else None}
@router.get('/devices')
def devices(limit:int=Query(100,ge=1,le=1000),cursor:str='',a=Depends(authenticated),db=Depends(database, scope="function")):
    rows=db.execute('SELECT * FROM devices WHERE account=? AND id>? ORDER BY id LIMIT ?',(a['account'],cursor,limit+1)).fetchall()
    return page(rows,limit,lambda r:device(db,r))
@router.get('/devices/{id}')
def get_device(id:str,a=Depends(authenticated),db=Depends(database, scope="function")): return device(db,owned(db,'devices',id,a['account']))
@router.patch('/devices/{id}')
def rename(id:str,body:Rename,a=Depends(authenticated),db=Depends(database, scope="function")):
    owned(db,'devices',id,a['account']); db.execute('UPDATE devices SET name=? WHERE id=?',(body.name,id))
    return device(db,owned(db,'devices',id,a['account']))
@router.post('/device-claims/challenge')
def challenge(body:Challenge,a=Depends(authenticated),db=Depends(database, scope="function")):
    id=uid(); nonce=b64(os.urandom(16)); expires=now()+60
    db.execute('DELETE FROM claims WHERE expires<?',(now()-86400,))
    db.execute('INSERT INTO claims(id,account,device,nonce,expires) VALUES(?,?,?,?,?)',(id,a['account'],body.device_id,nonce,expires))
    return {'challenge_id':id,'account_id':a['account'],'device_id':body.device_id,'nonce':nonce,'expires_at':iso(expires)}
@router.post('/device-claims/complete')
def claim(body:Proof,a=Depends(authenticated),db=Depends(database, scope="function")):
    c=owned(db,'claims',body.challenge_id,a['account'])
    d=one(db,'SELECT * FROM devices WHERE id=?',(c['device'],))
    if c['result']:
        if hmac.compare_digest(c['proof'],body.proof) and d and d['account']==a['account'] and d['ownership']==obj(c['result'])['ownership_id']: return obj(c['result'])
        fail(409,'claim_unavailable')
    if not d or c['expires']<now() or d['retired']: fail(409,'claim_unavailable')
    if not hmac.compare_digest(claim_proof(unseal(d['secret']),c),body.proof): fail(409,'claim_unavailable')
    if d['account'] and d['account']!=a['account']: fail(409,'claim_unavailable')
    ownership=d['ownership'] or uid()
    db.execute('UPDATE devices SET account=?,ownership=? WHERE id=?',(a['account'],ownership,d['id']))
    result={'device':device(db,owned(db,'devices',d['id'],a['account'])),'ownership_id':ownership}
    db.execute('UPDATE claims SET proof=?,result=? WHERE id=?',(body.proof,dump(result),c['id']))
    return result
@router.get('/rigs')
def rigs(limit:int=Query(100,ge=1,le=1000),cursor:str='',a=Depends(authenticated),db=Depends(database, scope="function")):
    rows=db.execute('SELECT * FROM rigs WHERE account=? AND id>? ORDER BY id LIMIT ?',(a['account'],cursor,limit+1)).fetchall()
    return page(rows,limit,lambda r:obj(r['data']))
def busy(db,account,ids):
    for l in db.execute('SELECT * FROM leases WHERE account=? AND expires>?',(account,now())):
        if set(obj(l['devices'])) & set(ids) and l['session']: fail(409,'rig_measuring')
@router.put('/rigs/{id}')
def put_rig(id:ID,body:Rig,a=Depends(authenticated),db=Depends(database, scope="function")):
    ids=[body.device_a_id,body.device_b_id]
    if len(set(ids))!=2: fail(422,'two_distinct_devices_required')
    for d in ids: owned(db,'devices',d,a['account'])
    old=one(db,'SELECT * FROM rigs WHERE id=?',(id,))
    if old and old['account']!=a['account']: fail(404,'not_found')
    value=obj(old['data']) if old else {'revision':0}
    if value['revision']!=body.expected_revision: fail(409,'revision_conflict')
    busy(db,a['account'],ids+[value.get('device_a_id'),value.get('device_b_id')])
    for d in ids:
        other=one(db,'SELECT rig FROM members WHERE device=? AND rig!=?',(d,id))
        if other: fail(409,'device_in_other_rig')
    result={'id':id,'name':body.name,'device_a_id':ids[0],'device_b_id':ids[1],'revision':value['revision']+1,'archived':False}
    db.execute('INSERT INTO rigs VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data',(id,a['account'],dump(result)))
    db.execute('DELETE FROM members WHERE rig=?',(id,))
    db.executemany('INSERT INTO members VALUES(?,?,?)',[(d,id,a['account']) for d in ids])
    return result
@router.patch('/rigs/{id}')
def archive(id:ID,body:Archive,a=Depends(authenticated),db=Depends(database, scope="function")):
    r=obj(owned(db,'rigs',id,a['account'])['data'])
    if r['revision']!=body.expected_revision: fail(409,'revision_conflict')
    busy(db,a['account'],[r['device_a_id'],r['device_b_id']]); r.update(archived=True,revision=r['revision']+1)
    db.execute('UPDATE rigs SET data=? WHERE id=?',(dump(r),id)); db.execute('DELETE FROM members WHERE rig=?',(id,))
    return r
@router.post('/collectors/{id}/presence')
def presence(id:ID,body:Presence,a=Depends(authenticated),db=Depends(database, scope="function")):
    ids=sorted(d.device_id for d in body.devices)
    if len(set(ids))!=len(ids): fail(422,'duplicate_device')
    for d in ids: owned(db,'devices',d,a['account'])
    if body.session_id:
        s=obj(owned(db,'sessions',body.session_id,a['account'])['start'])
        if s['collector_id']!=id or not set(ids)<=set(d['device_id'] for d in s['devices']): fail(409,'session_mismatch')
    l=one(db,'SELECT * FROM leases WHERE account=? AND collector=?',(a['account'],id))
    for other in db.execute('SELECT * FROM leases WHERE account=? AND collector!=? AND expires>?',(a['account'],id,now())):
        if set(ids)&set(obj(other['devices'])): fail(409,'collector_conflict')
    if body.lease_id is None:
        if not l or l['expires']<now():
            db.execute('DELETE FROM leases WHERE account=? AND collector=?',(a['account'],id))
            lease=uid(); expiry=now()+30
            db.execute('INSERT INTO leases VALUES(?,?,?,?,?,?,?)',(lease,a['account'],id,dump(ids),body.session_id,expiry,-1))
        else:
            if obj(l['devices'])!=ids: fail(409,'lease_devices_changed')
            lease,expiry=l['id'],l['expires']
        return {'lease_id':lease,'server_time':iso(now()),'expires_at':iso(expiry)}
    if not l or l['id']!=body.lease_id or l['expires']<now() or obj(l['devices'])!=ids or body.heartbeat_seq<=l['seq']: fail(409,'stale_presence')
    observed=body.observed_at.timestamp()
    if not now()-15<=observed<=now()+5: fail(409,'stale_presence')
    previous=one(db,'SELECT MAX(observed) t FROM presence WHERE lease=?',(l['id'],))['t']
    if previous is not None and observed<previous: fail(409,'stale_presence')
    expiry=now()+30
    db.execute('UPDATE leases SET expires=?,seq=?,session=? WHERE id=?',(expiry,body.heartbeat_seq,body.session_id,l['id']))
    for d in body.devices:
        db.execute('INSERT INTO presence VALUES(?,?,?,?,?) ON CONFLICT(device) DO UPDATE SET account=excluded.account,lease=excluded.lease,observed=excluded.observed,data=excluded.data',(d.device_id,a['account'],l['id'],observed,dump(d)))
    return {'lease_id':l['id'],'server_time':iso(now()),'expires_at':iso(expiry)}
