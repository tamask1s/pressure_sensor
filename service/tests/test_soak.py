"""Opt-in eight-hour dataset and actual SQLite backup/restore; removed after test."""
import os, sqlite3, time
import pytest
from .test_service import api,user,profile,Adapter
from pressure.common import *
from pressure import common
import simulator

@pytest.mark.skipif(os.environ.get('PRESSURE_SOAK')!='1',reason='explicit 576000 sample run')
def test_576000_samples_backup_restore(client,tmp_path):
    token,account=user(client); p=profile(2); adapter=Adapter(client,token)
    # The real simulator establishes claims, rig, immutable calibration snapshots.
    jobs=simulator.run(adapter,p,1,False,True); j=jobs[0]
    start_body=next(b for m,path,b in adapter.requests if m=='PUT' and path.startswith('/sessions/'))
    start=int(now())-28810; start_body['started_at']=iso(start); sid=uid()
    api(client,'PUT','/sessions/'+sid,start_body,token,201)
    segments=[{**s,'id':uid(),'boot_id':uid(),'utc_anchor':iso(start)} for s in j['segments']]
    gps={**j['gpsseg'],'id':uid(),'utc_anchor':iso(start)}
    fixids=[uid() for _ in range(28801)]
    def fix(t): return {'id':fixids[t],'segment_id':gps['id'],'captured_at':iso(start+t),'latitude':47.,'longitude':19.+(t%100)*.000002,'accuracy_m':2.,'speed_mps':1.,'heading_deg':90.}
    begin=time.monotonic()
    for second in range(0,28800,25):
        samples=[]
        for seg in segments:
            for seq in range(second*10,(second+25)*10):
                t=seq//10; frac=seq%10/10; a,b=fix(t),fix(t+1)
                loc={'latitude':47.,'longitude':a['longitude']+(b['longitude']-a['longitude'])*frac,'accuracy_m':2.,'speed_mps':1.,'fix_before_id':a['id'],'fix_after_id':b['id'],'method':'interpolated'}
                samples.append({'device_id':seg['device_id'],'boot_id':seg['boot_id'],'seq':seq,'time_segment_id':seg['id'],'uptime_ms':seq*100,'captured_at':iso(start+seq/10),'raw_count':0,'pressure_pa':10000000,'battery_mv':3900,'soc_pct':80,'flags':[],'location':loc})
        body={'batch_id':uid(),'time_segments':segments+[gps] if second==0 else [],'gps_fixes':[fix(t) for t in range(second if second==0 else second+1,second+26)],'samples':samples}
        receipt=api(client,'POST','/sessions/'+sid+'/batches',body,token)
        assert receipt['inserted']==sum(len(body[k]) for k in ['time_segments','gps_fixes','samples'])
        if second%3600==0: print('soak samples',second*20,'elapsed',round(time.monotonic()-begin,1),flush=True)
    inserted=time.monotonic()-begin
    end={'ended_at':iso(start+28800),'status':'completed','expected_samples_by_device':{s['device_id']:288000 for s in segments},'gaps':[]}
    api(client,'POST','/sessions/'+sid+'/complete',end,token)
    query=f'/map/cells?from={iso(start)}&to={iso(start+28800)}&bbox=18.99,46.99,19.01,47.01&session_ids={sid}'
    begin=time.monotonic(); result=api(client,'GET',query,token=token); map_seconds=time.monotonic()-begin
    assert sum(c['sample_count'] for c in result['cells'])==576000
    assert all(c['mean_pa']==10000000 for c in result['cells'])
    # Full-copy restore is tested separately on a bounded dataset. On a small
    # server, do not double the 720 MB soak database just to exercise that path.
    print(json.dumps({'samples':576000,'upload_seconds':round(inserted,2),'map_seconds':round(map_seconds,2),'database_bytes':Path(common.DB).stat().st_size}),flush=True)
    import shutil
    backup=tmp_path/'restored.sqlite3'
    if shutil.disk_usage(tmp_path).free < 2*Path(common.DB).stat().st_size+256*1024*1024:
        for path in tmp_path.glob('*.sqlite3*'): path.unlink()
        return
    with sqlite3.connect(common.DB) as source, sqlite3.connect(backup) as dest: source.backup(dest)
    with sqlite3.connect(backup) as restored:
        assert restored.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        assert restored.execute("SELECT COUNT(*) FROM records WHERE session=? AND kind='sample'",(sid,)).fetchone()[0]==576000
    original=common.DB; common.DB=str(backup)
    try:
        assert api(client,'GET',query,token=token)==result
        assert api(client,'GET','/sessions/'+sid,token=token)['status']=='completed'
    finally: common.DB=original
    print(json.dumps({'samples':576000,'upload_seconds':round(inserted,2),'map_seconds':round(map_seconds,2),'database_bytes':Path(common.DB).stat().st_size,'backup_restored':True}),flush=True)
    # Large fixtures have served their purpose; do not retain them in pytest cache.
    for path in tmp_path.glob('*.sqlite3*'): path.unlink()
