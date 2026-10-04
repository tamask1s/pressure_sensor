import copy
import json
import sqlite3
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import pytest
from pressure import common
from pressure.common import connect, one, obj, unseal
from pressure.admin import grant_admin
from .test_service import api, user, PASSWORD, Adapter
import simulator

def record(index=1):
    return {'device_id':f'hps-{index:012x}','secret_hex':f'{index:064x}',
        'sensor_serial':index,'protocol_version':2,'firmware_version':'SIMULATOR',
        'calibration':{'profile_id':'factory','sensor_serial':index,'range_min_pa':0,
            'range_max_pa':20000000,'scale':1,'offset_pa':0,'verified':False}}

def admin(client):
    token,account=user(client,'admin@example.test')
    with connect(True) as db: grant_admin(db,account,'test-cli')
    return token,account

def send(client,token,records,dry=True,expected=200):
    return api(client,'POST','/admin/devices/import?dry_run='+str(dry).lower(),records,token,expected)

def test_permissions_current_role_and_no_email_privilege(client):
    token,account=user(client,'tamkis@gmail.com')
    assert not api(client,'GET','/auth/session',token=token)['account']['is_admin']
    api(client,'GET','/admin/devices',expected=401)
    api(client,'GET','/admin/devices',token=token,expected=403)
    send(client,token,record(),False,403)
    api(client,'POST','/auth/register',{'email':'forged@example.test','password':PASSWORD,'is_admin':True},expected=422)
    with connect(True) as db: grant_admin(db,account,'test-cli')
    assert api(client,'GET','/auth/session',token=token)['account']['is_admin']
    send(client,token,record(),False)
    with connect(True) as db: db.execute('DELETE FROM account_roles WHERE account=?',(account,))
    api(client,'GET','/admin/devices',token=token,expected=403)
    send(client,token,record(2),False,403)
    with connect(True) as db: grant_admin(db,account,'test-cli')
    api(client,'DELETE','/account',{'password':PASSWORD},token,204)
    replacement,new_id=user(client,'tamkis@gmail.com')
    assert account!=new_id
    api(client,'GET','/admin/devices',token=replacement,expected=403)

def test_grant_requires_verified_existing_account(client):
    api(client,'POST','/auth/register',{'email':'pending@example.test','password':PASSWORD},expected=202)
    with connect(True) as db:
        id=one(db,'SELECT id FROM accounts')[0]
        for target in [id,'missing']:
            with pytest.raises(ValueError): grant_admin(db,target,'test-cli')
        assert not one(db,'SELECT 1 FROM account_roles')

def test_atomic_preview_replay_conflict_and_redaction(client,caplog):
    token,actor=admin(client); p=record()
    preview=send(client,token,[p,p])
    assert preview['counts']=={'new':1,'unchanged':0,'conflict':0}
    with connect() as db: assert not one(db,'SELECT 1 FROM devices')
    send(client,token,p,False)
    send(client,token,[p,p],False)
    for field,value in [('secret_hex','f'*64),('firmware_version','CHANGED')]:
        changed={**p,field:value}
        result=send(client,token,[record(2),changed])
        assert not result['valid'] and result['counts']['conflict']==1
        send(client,token,[record(2),changed],False,409)
    send(client,token,[record(2),{**record(2),'sensor_serial':3}],False,409)
    invalid={**record(2),p['secret_hex']:p['secret_hex']}
    response=send(client,token,[record(3),invalid],False,422)
    assert p['secret_hex'] not in json.dumps(response)
    for body in [[],[p]*501,{'devices':[p]}]: send(client,token,body,False,422)
    send(client,token,{**p,'firmware_version':'x'*524288},False,413)
    listed=api(client,'GET','/admin/devices',token=token)
    assert len(listed['items'])==1 and listed['items'][0]['owner'] is None
    assert listed['items'][0]['status']=='registered'
    with connect() as db:
        assert one(db,'SELECT count(*) FROM devices')[0]==1
        row=one(db,'SELECT * FROM devices')
        assert unseal(row['secret'])==p['secret_hex'] and row['secret']!=p['secret_hex']
        audits=[dict(row) for row in db.execute('SELECT * FROM admin_audit')]
    for output in [preview,listed,audits,caplog.text]:
        assert p['secret_hex'] not in json.dumps(output) and 'secret_hex' not in json.dumps(output)
    assert any(a['actor']==actor and a['outcome']=='conflict' and a['at']>0 for a in audits)
    assert any(a['outcome']=='invalid' for a in audits)

def test_web_csrf_and_owner_emails_only_for_admin(client):
    token,account=admin(client)
    api(client,'POST','/auth/login',{'email':'admin@example.test','password':PASSWORD,'client_kind':'web'},headers={'Origin':'https://testserver'})
    session=api(client,'GET','/auth/session')
    send(client,None,record(),False,403)
    api(client,'POST','/admin/devices/import?dry_run=false',record(),expected=403,headers={'Origin':'https://evil.test','X-CSRF-Token':session['csrf_token']})
    result=api(client,'POST','/admin/devices/import?dry_run=false',record(),headers={'Origin':'https://testserver','X-CSRF-Token':session['csrf_token']})
    assert result['valid']

def test_import_claim_measurement_owners_pagination_and_isolation(client):
    admin_token,actor=admin(client)
    records=[record(i) for i in range(1,5)]
    send(client,admin_token,records,False)
    customer,owner=user(client,'owner@example.test')
    jobs=simulator.run(Adapter(client,customer),{'devices':records},1,False,True)
    before=api(client,'GET','/devices',token=customer)
    assert len(before['items'])==4
    replay=send(client,admin_token,records,False)
    assert replay['counts']['unchanged']==4
    assert api(client,'GET','/devices',token=customer)==before
    page=api(client,'GET','/admin/devices?limit=2',token=admin_token)
    assert len(page['items'])==2
    assert all(d['owner']=={'account_id':owner,'email':'owner@example.test'} and d['status']=='paired' for d in page['items'])
    rest=api(client,'GET','/admin/devices?limit=2&cursor='+page['next_cursor'],token=admin_token)
    assert len(rest['items'])==2 and rest['next_cursor'] is None
    assert set(d['device_id'] for d in page['items']).isdisjoint(d['device_id'] for d in rest['items'])
    match=api(client,'GET','/admin/devices?q='+records[2]['device_id'].upper(),token=admin_token)
    assert [d['device_id'] for d in match['items']]==[records[2]['device_id']]
    assert api(client,'GET','/devices',token=admin_token)['items']==[]
    for job in jobs:
        api(client,'GET','/sessions/'+job['id']+'/samples',token=admin_token,expected=404)
        assert api(client,'GET','/sessions/'+job['id']+'/samples',token=customer)['items']
    api(client,'GET','/admin/devices',token=customer,expected=403)

def test_concurrent_replay_is_serialized(client):
    token,_=admin(client)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(lambda _:send(client,token,[record(1),record(2)],False),range(2)))
    assert sorted(r['counts']['new'] for r in results)==[0,2]
    with connect() as db: assert one(db,'SELECT count(*) FROM devices')[0]==2

def test_v1_migration_keeps_existing_data_and_is_idempotent(tmp_path,monkeypatch):
    path=tmp_path/'v1.sqlite3'
    with sqlite3.connect(path) as db:
        db.executescript((common.BASE/'schema.sql').read_text())
        db.execute("INSERT INTO accounts VALUES('original','test@example.test','password',1)")
        db.execute("INSERT INTO devices VALUES('hps-000000000001','encrypted','{}','original','ownership','original name',0)")
        before=db.execute('SELECT * FROM devices').fetchall()
    monkeypatch.setattr(common,'DB',str(path))
    common.init(); common.init()
    with sqlite3.connect(path) as db:
        assert db.execute('PRAGMA user_version').fetchone()[0]==2
        assert db.execute('SELECT * FROM devices').fetchall()==before
        assert not db.execute('SELECT * FROM account_roles').fetchall()
