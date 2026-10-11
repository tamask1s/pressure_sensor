from .test_service import api, uploaded
from pressure.common import uid, iso, now
import copy

def test_single_sensor_rig_upload_and_completion(client):
    token, owner, profile, adapter, jobs = uploaded(client, False, 2)
    dev = profile['devices'][0]['device_id']
    old = api(client, 'GET', '/rigs', token=token)['items'][0]
    api(client, 'PATCH', '/rigs/'+old['id'], {'archived': True, 'expected_revision': old['revision']}, token)
    rig = api(client, 'PUT', '/rigs/'+uid(), {'name': 'Single', 'device_a_id': dev, 'expected_revision': 0}, token)
    assert rig['device_b_id'] is None
    api(client, 'PUT', '/rigs/'+uid(), {'name': 'Duplicate', 'device_a_id': dev, 'device_b_id': dev, 'expected_revision': 0}, token, 422)
    start = copy.deepcopy(next(body for method, path, body in adapter.requests if method=='PUT' and path.startswith('/sessions/')))
    start.update(rig_id=rig['id'], rig_revision=rig['revision'], devices=[start['devices'][0]])
    sid=uid()
    api(client, 'PUT', '/sessions/'+sid, start, token, 201)
    batch=copy.deepcopy(next(body for method,path,body in adapter.requests if '/batches' in path))
    batch['batch_id']=uid()
    boot=uid()
    remap={s['id']:uid() for s in batch['time_segments']}
    batch['time_segments']=[{**s,'id':remap[s['id']],'boot_id':boot if s['device_id'] else None} for s in batch['time_segments'] if s['device_id'] in (None,dev)]
    batch['samples']=[{**s,'boot_id':boot,'time_segment_id':remap[s['time_segment_id']], 'flags':s['flags']+['simulated']} for s in batch['samples'] if s['device_id']==dev]
    api(client, 'POST', '/sessions/'+sid+'/batches', batch, token)
    api(client, 'POST', '/sessions/'+sid+'/complete', {'ended_at':iso(now()),'status':'completed','expected_samples_by_device':{dev:len(batch['samples'])},'gaps':[]}, token)
    rows=api(client, 'GET', '/sessions/'+sid+'/samples', token=token)['items']
    assert len(rows)==len(batch['samples']) and all(s['device_id']==dev for s in rows)
    assert all('simulated' in s['flags'] for s in rows)
    invalid=copy.deepcopy(start); invalid['devices'][0]['role']='B'
    api(client, 'PUT', '/sessions/'+uid(), invalid, token, 422)
