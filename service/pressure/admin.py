"""Local admin only. Provisioning secrets never go through HTTP."""
import argparse, shutil, sys
from .common import *
from .models import Provision

def provision(db,p,transfer=False):
    data=obj(dump(p)); id=data.pop('device_id'); secret=data.pop('secret_hex')
    existing=one(db,'SELECT * FROM devices WHERE id=?',(id,))
    if existing:
        if not transfer: raise ValueError('Device already imported; use explicit transfer after syncing')
        active=one(db,"SELECT 1 FROM sessions WHERE account=? AND status='recording' AND EXISTS(SELECT 1 FROM json_each(start,'$.devices') WHERE json_extract(value,'$.device_id')=?)",(existing['account'],id))
        if active: raise ValueError('Complete all recordings before transfer')
        if unseal(existing['secret'])==secret: raise ValueError('Transfer requires a new hardware secret and BLE PIN/bonds reset')
        db.execute('DELETE FROM members WHERE device=?',(id,)); db.execute('DELETE FROM presence WHERE device=?',(id,)); db.execute('DELETE FROM claims WHERE device=?',(id,))
        for row in db.execute('SELECT id,data FROM rigs WHERE account=?',(existing['account'],)).fetchall():
            r=obj(row['data'])
            if id in (r['device_a_id'],r['device_b_id']):
                r.update(archived=True,revision=r['revision']+1); db.execute('UPDATE rigs SET data=? WHERE id=?',(dump(r),row['id'])); db.execute('DELETE FROM members WHERE rig=?',(row['id'],))
        db.execute('DELETE FROM leases WHERE account=?',(existing['account'],))
        db.execute('UPDATE devices SET secret=?,metadata=?,account=NULL,ownership=NULL,retired=0 WHERE id=?',(seal(secret),dump(data),id))
    else: db.execute('INSERT INTO devices(id,secret,metadata,name) VALUES(?,?,?,?)',(id,seal(secret),dump(data),id))
def main():
    p=argparse.ArgumentParser(); sub=p.add_subparsers(dest='command',required=True)
    for name in ['import','transfer']:
        s=sub.add_parser(name); s.add_argument('file')
    s=sub.add_parser('simulator-profile'); s.add_argument('file'); s.add_argument('--pairs',type=int,default=2)
    s=sub.add_parser('backup'); s.add_argument('file')
    sub.add_parser('init')
    args=p.parse_args(); init()
    if args.command=='init': return
    if args.command=='backup':
        if Path(args.file).exists(): raise ValueError('Backup destination already exists')
        if shutil.disk_usage(str(Path(args.file).parent)).free < 2*Path(DB).stat().st_size+256*1024*1024: raise ValueError('Insufficient space for backup')
        oldmask=os.umask(0o077)
        try:
            with sqlite3.connect(DB) as src, sqlite3.connect(args.file) as dst:
                def progress(status,remaining,total):
                    if shutil.disk_usage(str(Path(args.file).parent)).free<256*1024*1024:
                        raise RuntimeError('Stopped backup to preserve free space')
                src.backup(dst,pages=256,progress=progress)
                assert dst.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        finally: os.umask(oldmask)
        print('Backup verified:',args.file); return
    if args.command=='simulator-profile':
        if not 1<=args.pairs<=10: raise ValueError('pairs must be 1..10')
        devices=[]
        for _ in range(args.pairs*2):
            id='hps-'+os.urandom(6).hex()
            devices.append({'device_id':id,'secret_hex':os.urandom(32).hex(),'sensor_serial':0,'protocol_version':2,'firmware_version':'SIMULATOR','calibration':{'profile_id':'simulator-0-200bar','sensor_serial':0,'range_min_pa':0,'range_max_pa':20000000,'scale':1,'offset_pa':0,'verified':False}})
        # Reserve the file before changing DB; do not overwrite a previous profile.
        with open(os.open(args.file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f:
            with connect(True) as db:
                for d in devices: provision(db,Provision.model_validate(d))
                f.write(json.dumps({'warning':'Simulated devices only. Keep this file private.','devices':devices},indent=2))
        print('Imported simulated devices. Private profile:',args.file); return
    content=obj(Path(args.file).read_text()); devices=content if isinstance(content,list) else content.get('devices',[content])
    with connect(True) as db:
        for d in devices: provision(db,Provision.model_validate(d),args.command=='transfer')
    print('Imported devices:',len(devices))
if __name__=='__main__': main()
