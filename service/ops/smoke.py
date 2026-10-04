"""Temporary production integration account, no external e-mail messages."""
import argparse, json, os, pwd, sys
from pathlib import Path
for line in Path('/etc/pressure_sensor/service.env').read_text().splitlines():
    k,v=line.split('=',1); os.environ[k]=json.loads(v)
sys.path.insert(0,'/opt/pressure_sensor/current/service')
sys.path.insert(0,'/opt/pressure_sensor/deps')
from pressure.common import *
from pressure.security import password_hash
from pressure.admin import provision, grant_admin
from pressure.models import Provision
p=argparse.ArgumentParser(); p.add_argument('action',choices=['prepare','cleanup','smtp']); p.add_argument('--admin',action='store_true',help='Temporary admin account with unimported device JSON for the browser test'); args=p.parse_args()
file=Path('/tmp/pressure-smoke-private.json')
if args.action=='smtp':
    import smtplib,ssl
    with smtplib.SMTP(os.environ['PRESSURE_SMTP_HOST'],int(os.environ['PRESSURE_SMTP_PORT']),timeout=20) as s:
        s.starttls(context=ssl.create_default_context()); s.login(os.environ['PRESSURE_SMTP_USER'],Path(os.environ['PRESSURE_SMTP_PASSWORD_FILE']).read_text().strip()); code,_=s.noop(); assert code==250
    print('SMTP STARTTLS + authentication + NOOP successful. No message sent.')
elif args.action=='prepare':
    if file.exists(): raise SystemExit('Clean up the previous integration account first')
    id=uid(); password=random(); email='pressure-smoke-'+id+'@example.invalid'; profile={'devices':[]}
    with connect(True) as db:
        db.execute('INSERT INTO accounts VALUES(?,?,?,1)',(id,email,password_hash(password)))
        if args.admin: grant_admin(db,id,'server:integration-test')
        for _ in range(4):
            d={'device_id':'hps-'+os.urandom(6).hex(),'secret_hex':os.urandom(32).hex(),'sensor_serial':0,'protocol_version':2,'firmware_version':'INTEGRATION-TEST','calibration':{'profile_id':'integration-test','sensor_serial':0,'range_min_pa':0,'range_max_pa':20000000,'scale':1,'offset_pa':0,'verified':False}}
            if not args.admin: provision(db,Provision.model_validate(d))
            profile['devices'].append(d)
    with open(os.open(file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f: f.write(dump({'id':id,'email':email,'password':password,'profile':profile}))
    user=pwd.getpwnam('graphyt2'); os.chown(file,user.pw_uid,user.pw_gid)
    print('Temporary integration account prepared; credentials kept in private file.')
else:
    c=obj(file.read_text())
    if not c['email'].startswith('pressure-smoke-') or not c['email'].endswith('@example.invalid'): raise SystemExit('Not a smoke account')
    with connect(True) as db:
        for d in c['profile']['devices']: db.execute('UPDATE devices SET account=NULL,ownership=NULL WHERE id=?',(d['device_id'],))
        db.execute('DELETE FROM accounts WHERE id=? AND email=?',(c['id'],c['email']))
        for d in c['profile']['devices']: db.execute('DELETE FROM devices WHERE id=?',(d['device_id'],))
    file.unlink(); print('Integration account and its simulated data removed.')
