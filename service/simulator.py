#!/usr/bin/env python3
"""Python 3 standard library HTTPS collector simulator. Never emulates a real sensor."""
import argparse, base64, getpass, hashlib, hmac, json, math, ssl, time, urllib.error, urllib.request
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

def uid(): return str(uuid4())
def utc(t): return datetime.fromtimestamp(t,timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
def b64(v): return base64.urlsafe_b64encode(v).decode().rstrip('=')
class API:
    def __init__(self,url):
        self.url=url.rstrip('/'); self.access=None; self.refresh=None
        if not self.url.startswith('https://') and not self.url.startswith('http://127.0.0.1:'): raise ValueError('HTTPS URL required')
        # Deliberately do not follow redirects: bearer tokens must stay on the chosen origin.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self,*args,**kwargs): return None
        self.client=urllib.request.build_opener(NoRedirect)
    def call(self,method,path,body=None,retry=True):
        data=json.dumps(body,separators=(',',':')).encode() if body is not None else None
        for attempt in range(5):
            headers={'Content-Type':'application/json','Accept':'application/json'}
            if self.access: headers['Authorization']='Bearer '+self.access
            try:
                with self.client.open(urllib.request.Request(self.url+path,data,headers,method=method),timeout=30) as r:
                    raw=r.read(); return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                if e.code==401 and self.refresh and retry:
                    tokens=self.call('POST','/auth/refresh',{'refresh_token':self.refresh},retry=False)
                    self.access=tokens['access_token']; self.refresh=tokens['refresh_token']
                    return self.call(method,path,body,retry=False)
                if e.code in (429,502,503,504) and attempt<4: time.sleep(min(30,2**attempt)); continue
                raise RuntimeError(f'{e.code}: {e.read().decode()[:400]}') from None
            except (OSError,TimeoutError):
                if attempt==4: raise
                time.sleep(2**attempt)

def run(api,profile,seconds,realtime,gps=True):
    devices=[]
    for p in profile['devices']:
        id=p['device_id']; c=api.call('POST','/device-claims/challenge',{'device_id':id})
        message=f"HPS-CLAIM-v1\n{id}\n{c['account_id']}\n{c['challenge_id']}\n".encode()+base64.urlsafe_b64decode(c['nonce']+'==')
        proof=b64(hmac.digest(bytes.fromhex(p['secret_hex']),message,'sha256'))
        d=api.call('POST','/device-claims/complete',{'challenge_id':c['challenge_id'],'proof':proof})['device']; devices.append(d)
    rigs=api.call('GET','/rigs?limit=1000')['items']; jobs=[]; start=int(time.time())-(0 if realtime else seconds+5)
    for i in range(0,len(devices),2):
        pair=devices[i:i+2]
        if len(pair)!=2: break
        rig=next((r for r in rigs if not r['archived'] and r['device_a_id']==pair[0]['id'] and r['device_b_id']==pair[1]['id']),None)
        if not rig: rig=api.call('PUT','/rigs/'+uid(),{'name':f'SZIMULÁTOR pár {i//2+1}','device_a_id':pair[0]['id'],'device_b_id':pair[1]['id'],'expected_revision':0})
        sid=uid(); collector=uid(); snaps=[{'device_id':d['id'],'ownership_id':d['ownership_id'],'role':role,'calibration':d['calibration']} for d,role in zip(pair,['A','B'])]
        api.call('PUT','/sessions/'+sid,{'collector_id':collector,'rig_id':rig['id'],'rig_revision':rig['revision'],'name':f'SZIMULÁTOR – {utc(start)} – {i//2+1}','started_at':utc(start),'gps_enabled':gps,'devices':snaps})
        segments=[{'id':uid(),'device_id':d['id'],'boot_id':uid(),'uptime_anchor_ms':0,'utc_anchor':utc(start),'uncertainty_ms':10,'source':'phone'} for d in pair]
        gpsseg={'id':uid(),'device_id':None,'boot_id':None,'uptime_anchor_ms':0,'utc_anchor':utc(start),'uncertainty_ms':10,'source':'phone'}
        fixids=[uid() for _ in range(seconds+1)]
        jobs.append({'id':sid,'collector':collector,'pair':pair,'segments':segments,'gpsseg':gpsseg,'fixids':fixids,'lease':None,'heartbeat':0,'row':i//2,'sent':set()})
    for sec in range(seconds):
        if realtime: time.sleep(max(0,start+sec+1-time.time()))
        for j in jobs:
            def fix(n):
                return {'id':j['fixids'][n],'segment_id':j['gpsseg']['id'],'captured_at':utc(start+n),'latitude':47.0+j['row']*.00015,'longitude':19.0+n*.000025,'accuracy_m':2,'speed_mps':1.9,'heading_deg':90}
            samples=[]
            for d,seg in zip(j['pair'],j['segments']):
                for n in range(10):
                    seq=sec*10+n; raw=round(-12000+22000*(.5+.5*math.sin(sec/12+j['row'])))
                    pa=round((raw+16000)/32000*20000000)
                    loc={'latitude':fix(sec)['latitude'],'longitude':19+(sec+n/10)*.000025,'accuracy_m':2,'speed_mps':1.9,'fix_before_id':j['fixids'][sec],'fix_after_id':j['fixids'][sec+1],'method':'interpolated'} if gps else None
                    samples.append({'device_id':d['id'],'boot_id':seg['boot_id'],'seq':seq,'time_segment_id':seg['id'],'uptime_ms':seq*100,'captured_at':utc(start+seq/10),'raw_count':raw,'pressure_pa':pa,'battery_mv':3900,'soc_pct':80,'flags':[] if gps else ['gps_disabled'],'location':loc})
            batch={'batch_id':uid(),'time_segments':j['segments']+[j['gpsseg']] if sec==0 else [],'gps_fixes':[fix(n) for n in [sec,sec+1] if n not in j['sent']] if gps else [],'samples':samples}
            ack=api.call('POST','/sessions/'+j['id']+'/batches',batch)
            assert ack['inserted']+ack['duplicates']==sum(len(batch[k]) for k in ['time_segments','gps_fixes','samples'])
            # Exercise identical network replay without duplicating measurements.
            if sec==0: assert api.call('POST','/sessions/'+j['id']+'/batches',batch)==ack
            j['sent'].update([sec,sec+1])
            if realtime and sec%10==0:
                def presence():
                    return {'lease_id':j['lease'],'heartbeat_seq':j['heartbeat'],'observed_at':utc(time.time()),'session_id':j['id'],'devices':[{'device_id':d['id'],'boot_id':seg['boot_id'],'ble_connected':True,'last_seq':sec*10+9,'sample_age_ms':100,'pressure_pa':samples[-1]['pressure_pa'],'battery_mv':3900,'soc_pct':80,'sensor_ok':True,'sd_state':'simulated'} for d,seg in zip(j['pair'],j['segments'])]}
                r=api.call('POST','/collectors/'+j['collector']+'/presence',presence()); j['lease']=r['lease_id']; j['heartbeat']+=1
                api.call('POST','/collectors/'+j['collector']+'/presence',presence()); j['heartbeat']+=1
        if sec%10==0: print(f'{sec+1}/{seconds} s; {len(jobs)} pár feltöltve',flush=True)
    for j in jobs:
        api.call('POST','/sessions/'+j['id']+'/complete',{'ended_at':utc(start+seconds),'status':'completed','expected_samples_by_device':{d['id']:seconds*10 for d in j['pair']},'gaps':[]})
    print('Kész. A SZIMULÁTOR mérések az Előzmények és Térkép nézetben láthatók.')
    return jobs

def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--url',default='https://timeonion.com/pressure_sensor/api/v1'); p.add_argument('--email',required=True); p.add_argument('--profile'); p.add_argument('--seconds',type=int,default=60); p.add_argument('--fast',action='store_true'); p.add_argument('--no-gps',action='store_true'); p.add_argument('--register',action='store_true'); args=p.parse_args()
    api=API(args.url); password=getpass.getpass('Jelszó: ')
    if args.register:
        api.call('POST','/auth/register',{'email':args.email,'password':password}); print('Erősítsd meg az e-mailt, majd futtasd --register nélkül.'); return
    if not args.profile or not 1<=args.seconds<=28800: p.error('--profile szükséges, --seconds 1..28800')
    tokens=api.call('POST','/auth/login',{'email':args.email,'password':password,'client_kind':'native'}); api.access=tokens['access_token']; api.refresh=tokens['refresh_token']
    try: run(api,json.loads(Path(args.profile).read_text()),args.seconds,not args.fast,not args.no_gps)
    finally: api.call('POST','/auth/logout')
if __name__=='__main__': main()
