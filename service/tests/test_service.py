import base64, copy, json, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import pytest
from pressure.common import *
from pressure.security import claim_proof, password_hash
from pressure.admin import provision
from pressure.models import Provision
from pressure.grid import aggregate
import simulator

PASSWORD='a-test-password-1234'
def api(c,method,path,body=None,token=None,expected=200,headers=None):
    response=c.request(method,'/pressure_sensor/api/v1'+path,json=body,headers={**({'Authorization':'Bearer '+token} if token else {}),**(headers or {})})
    assert response.status_code==expected,response.text
    return response.json() if response.content else {}
def user(c,email='a@example.test'):
    api(c,'POST','/auth/register',{'email':email,'password':PASSWORD},expected=202)
    with connect() as db:
        a=one(db,'SELECT * FROM accounts WHERE email=?',(email,)); mail=one(db,'SELECT payload FROM outbox WHERE account=?',(a['id'],))
        token=obj(unseal(mail['payload']))['body'].split('token=')[1].split('\n')[0]
    api(c,'POST','/auth/verify-email',{'token':token},expected=204)
    login=api(c,'POST','/auth/login',{'email':email,'password':PASSWORD,'client_kind':'native'})
    return login['access_token'],a['id']
def profile(count=4):
    result={'devices':[]}
    with connect(True) as db:
        for _ in range(count):
            d={'device_id':'hps-'+os.urandom(6).hex(),'secret_hex':os.urandom(32).hex(),'sensor_serial':1,'protocol_version':2,'calibration':{'profile_id':'test','sensor_serial':1,'range_min_pa':0,'range_max_pa':20000000,'scale':1,'offset_pa':0,'verified':False}}
            provision(db,Provision.model_validate(d)); result['devices'].append(d)
    return result
class Adapter:
    def __init__(self,c,token): self.c=c; self.token=token; self.requests=[]
    def call(self,method,path,body=None):
        self.requests.append((method,path,copy.deepcopy(body)))
        return api(self.c,method,path,body,self.token,201 if method=='PUT' and path.startswith('/sessions/') else 200)
def uploaded(c,gps=True,count=4,seconds=2):
    token,id=user(c); p=profile(count); adapter=Adapter(c,token); jobs=simulator.run(adapter,p,seconds,False,gps)
    return token,id,p,adapter,jobs

def test_claim_fixture():
    fixture=obj((Path(__file__).parents[2]/'contracts/fixtures.json').read_text())['claim']
    assert claim_proof(fixture['secret_hex'],{'device':fixture['device_id'],'account':fixture['account_id'],'id':fixture['challenge_id'],'nonce':fixture['nonce']})==fixture['proof']
def test_grid_fixture():
    f=obj((Path(__file__).parents[2]/'contracts/fixtures.json').read_text())['map']
    rows=[]; fixes={}
    for s in f['sessions']:
        fixes[s['id']]=[{'id':str(i),'captured_at':iso(i),'segment_id':'gps','latitude':47.,'longitude':19.,'accuracy_m':2.,'speed_mps':2.} for i in [0,1]]
        for role in ['A','B']:
            values=s[role+'_pa']; rows.append({'session':s['id'],'second':0,'role':role,'mean':sum(values)/len(values),'min':min(values),'max':max(values),'n':len(values)})
    result=aggregate(rows,fixes,32634,10,[18,46,20,48]); assert len(result)==1
    for k,v in f['expected'].items():
        if k!='cell_count': assert result[0][k]==v

def test_multi_pair_upload_map_isolation_and_csv(client):
    token,owner,p,adapter,jobs=uploaded(client)
    other,other_id=user(client,'b@example.test')
    assert len(api(client,'GET','/devices',token=token)['items'])==4
    assert api(client,'GET','/devices',token=other)['items']==[]
    for job in jobs:
        sid=job['id']
        for path in [f'/sessions/{sid}',f'/sessions/{sid}/samples',f'/sessions/{sid}/track',f'/sessions/{sid}/export.csv',f'/sessions/{sid}/series?from={iso(now()-100)}&to={iso(now())}']:
            api(client,'GET',path,token=other,expected=404)
        samplepage=api(client,'GET',f'/sessions/{sid}/samples?limit=7',token=token)
        assert len(samplepage['items'])==7 and samplepage['next_cursor']
        page2=api(client,'GET',f'/sessions/{sid}/samples?limit=7&cursor='+samplepage['next_cursor'],token=token)
        assert samplepage['items']!=page2['items']
        csv=client.get('/pressure_sensor/api/v1/sessions/'+sid+'/export.csv',headers={'Authorization':'Bearer '+token}); assert csv.status_code==200 and len(csv.text.splitlines())==41
    query=f'/map/cells?from={iso(now()-100)}&to={iso(now())}&bbox=18,46,20,48'
    cells=api(client,'GET',query,token=token)['cells']; assert cells and sum(c['sample_count'] for c in cells)==80
    assert api(client,'GET',query,token=other)['cells']==[]
    dev=p['devices'][0]['device_id']
    api(client,'PATCH','/devices/'+dev,{'name':'stolen'},other,404)
    api(client,'PUT','/rigs/'+uid(),{'name':'bad','device_a_id':dev,'device_b_id':p['devices'][1]['device_id'],'expected_revision':0},other,404)
    for method,path,body in adapter.requests:
        if '/batches' in path:
            api(client,'POST',path,body,token)
            changed=copy.deepcopy(body); changed['samples'][0]['pressure_pa']+=1
            api(client,'POST',path,changed,token,409)
            api(client,'POST',path,body,other,404)
            new=copy.deepcopy(body); new['batch_id']=uid(); api(client,'POST',path,new,token,409)
            break

def test_gpsless_and_atomic_rollback(client):
    token,owner,p,adapter,jobs=uploaded(client,False,2)
    job=jobs[0]
    assert all(s['location'] is None for s in api(client,'GET','/sessions/'+job['id']+'/samples',token=token)['items'])
    start=next(body for m,path,body in adapter.requests if m=='PUT' and path.startswith('/sessions/'))
    sid=uid(); api(client,'PUT','/sessions/'+sid,start,token,201)
    batch=copy.deepcopy(next(body for m,path,body in adapter.requests if '/batches' in path))
    batch['batch_id']=uid()
    # Global device/boot/seq identity must not appear in a different session.
    api(client,'POST','/sessions/'+sid+'/batches',batch,token,409)
    with connect() as db: assert one(db,'SELECT count(*) n FROM records WHERE session=?',(sid,))['n']==0
    api(client,'POST','/sessions/'+sid+'/complete',{'ended_at':iso(now()),'status':'completed','expected_samples_by_device':{p['devices'][0]['device_id']:1},'gaps':[]},token,409)

def test_claim_expiry_replay_parallel_and_transfer(client):
    token,owner=user(client); p=profile(2); d=p['devices'][0]
    challenge=api(client,'POST','/device-claims/challenge',{'device_id':d['device_id']},token)
    with connect() as db: c=dict(one(db,'SELECT * FROM claims WHERE id=?',(challenge['challenge_id'],)))
    proof=claim_proof(d['secret_hex'],c); body={'challenge_id':c['id'],'proof':proof}
    with ThreadPoolExecutor(2) as pool:
        responses=list(pool.map(lambda _:api(client,'POST','/device-claims/complete',body,token),range(2)))
    assert responses[0]['ownership_id']==responses[1]['ownership_id']
    another=api(client,'POST','/device-claims/challenge',{'device_id':d['device_id']},token)
    api(client,'POST','/device-claims/complete',{'challenge_id':another['challenge_id'],'proof':proof},token,409)
    with connect(True) as db: db.execute('UPDATE claims SET expires=0 WHERE id=?',(another['challenge_id'],))
    api(client,'POST','/device-claims/complete',{'challenge_id':another['challenge_id'],'proof':proof},token,409)
    with connect(True) as db:
        changed={**d,'secret_hex':os.urandom(32).hex()}; provision(db,Provision.model_validate(changed),True)
    api(client,'GET','/devices/'+d['device_id'],token=token,expected=404)

def test_auth_web_csrf_rotation_expiry_reset_delete(client):
    token,owner=user(client)
    login=api(client,'POST','/auth/login',{'email':'a@example.test','password':PASSWORD,'client_kind':'native'})
    refreshed=api(client,'POST','/auth/refresh',{'refresh_token':login['refresh_token']})
    api(client,'POST','/auth/refresh',{'refresh_token':login['refresh_token']},expected=401)
    api(client,'GET','/auth/session',token=login['access_token'],expected=401)
    api(client,'POST','/auth/logout',token=refreshed['access_token'],expected=204)
    api(client,'GET','/auth/session',token=refreshed['access_token'],expected=401)
    with connect(True) as db: db.execute('UPDATE auth SET access_until=0 WHERE account=?',(owner,))
    api(client,'GET','/auth/session',token=token,expected=401)
    api(client,'POST','/auth/login',{'email':'a@example.test','password':PASSWORD,'client_kind':'web'},expected=403)
    api(client,'POST','/auth/login',{'email':'a@example.test','password':PASSWORD,'client_kind':'web'},headers={'Origin':'https://testserver'})
    session=api(client,'GET','/auth/session')
    api(client,'POST','/auth/logout',expected=403)
    api(client,'POST','/auth/logout',expected=204,headers={'Origin':'https://testserver','X-CSRF-Token':session['csrf_token']})
    api(client,'POST','/auth/forgot-password',{'email':'a@example.test'},expected=202)
    with connect() as db: reset=obj(unseal(one(db,'SELECT payload FROM outbox WHERE account=?',(owner,))['payload']))['body'].split('token=')[1].split('\n')[0]
    api(client,'POST','/auth/reset-password',{'token':reset,'new_password':PASSWORD+'new'},expected=204)
    login=api(client,'POST','/auth/login',{'email':'a@example.test','password':PASSWORD+'new','client_kind':'native'})
    api(client,'DELETE','/account',{'password':PASSWORD+'new'},login['access_token'],204)
    api(client,'GET','/auth/session',token=login['access_token'],expected=401)

def test_presence_stale_conflict_and_fresh(client):
    token,owner,p,adapter,jobs=uploaded(client,False,2); j=jobs[0]
    body={'heartbeat_seq':0,'observed_at':iso(0),'devices':[{'device_id':d['id'],'ble_connected':True,'sample_age_ms':0,'pressure_pa':0,'sensor_ok':True,'sd_state':'ok'} for d in j['pair']]}
    path='/collectors/'+j['collector']+'/presence'
    lease=api(client,'POST',path,body,token)
    assert api(client,'GET','/devices/'+j['pair'][0]['id'],token=token)['presence'] is None
    body['lease_id']=lease['lease_id']; api(client,'POST',path,body,token,409)
    body['observed_at']=iso(now()); api(client,'POST',path,body,token)
    assert api(client,'GET','/devices/'+j['pair'][0]['id'],token=token)['presence']['state']=='fresh'
    api(client,'POST',path,body,token,409)
    api(client,'POST','/collectors/'+uid()+'/presence',{**body,'lease_id':None},token,409)
    with connect(True) as db: db.execute('UPDATE leases SET expires=0')
    assert api(client,'GET','/devices/'+j['pair'][0]['id'],token=token)['presence']['state']=='last_seen'
    body['heartbeat_seq']=1; api(client,'POST',path,body,token,409)

def test_body_limit_and_invalid_input(client):
    r=client.post('/pressure_sensor/api/v1/auth/register',content=b'x'*524289); assert r.status_code==413
    api(client,'POST','/auth/register',{'email':'bad','password':'short'},expected=422)
    api(client,'POST','/auth/register',{'email':'a@example.test','password':PASSWORD},expected=403,headers={'Origin':'https://evil.test'})

def test_real_backup_restore_with_api(client,tmp_path):
    import sqlite3
    from pressure import common
    token,owner,p,adapter,jobs=uploaded(client,True,4,10)
    query=f'/map/cells?from={iso(now()-100)}&to={iso(now())}&bbox=18,46,20,48'
    expected=api(client,'GET',query,token=token)
    assert sum(c['sample_count'] for c in expected['cells'])==400
    dest=tmp_path/'restore.sqlite3'
    with sqlite3.connect(common.DB) as source,sqlite3.connect(dest) as target: source.backup(target)
    original=common.DB; common.DB=str(dest)
    try:
        with connect() as db: assert one(db,'PRAGMA integrity_check')[0]=='ok'
        assert api(client,'GET',query,token=token)==expected
        assert len(api(client,'GET','/devices',token=token)['items'])==4
    finally: common.DB=original


def test_windows_simulator_json_list_import_and_claim(client,tmp_path,monkeypatch):
    """Windows newSimulatorDevices() exports a bare list, without firmware_version."""
    from pressure import admin
    devices=[]
    for serial in [123456,654321]:
        device='hps-02'+os.urandom(5).hex()
        devices.append({'device_id':device,'secret_hex':os.urandom(32).hex(),
                        'sensor_serial':serial,'protocol_version':2,
                        'calibration':{'profile_id':device+'-0-20000000',
                                       'sensor_serial':serial,'range_min_pa':0,
                                       'range_max_pa':20000000,'scale':1,
                                       'offset_pa':0,'verified':True}})
    source=tmp_path/'devices.simulator.json'
    source.write_text(json.dumps(devices))
    monkeypatch.setattr('sys.argv',['pressure.admin','import',str(source)])
    admin.main()
    token,account=user(client)
    for d in devices:
        c=api(client,'POST','/device-claims/challenge',{'device_id':d['device_id']},token)
        proof=claim_proof(d['secret_hex'],{'device':d['device_id'],'account':c['account_id'],
                                         'id':c['challenge_id'],'nonce':c['nonce']})
        result=api(client,'POST','/device-claims/complete',
                   {'challenge_id':c['challenge_id'],'proof':proof},token)
        assert result['device']['calibration']==d['calibration']
        assert 'secret_hex' not in result['device']
        with connect() as db:
            stored=one(db,'SELECT secret FROM devices WHERE id=?',(d['device_id'],))['secret']
            assert stored!=d['secret_hex'] and unseal(stored)==d['secret_hex']
    assert len(api(client,'GET','/devices',token=token)['items'])==2
