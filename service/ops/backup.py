"""Daily, compressed local backup, at most two copies; never touches another service."""
import gzip, json, os, shutil, sqlite3, tempfile
from datetime import datetime, timezone
from pathlib import Path
root=Path('/var/backups/pressure_sensor'); root.mkdir(exist_ok=True)
source=Path('/var/lib/pressure_sensor/pressure.sqlite3')
if not source.exists(): raise SystemExit('No pressure database')
for line in Path('/etc/pressure_sensor/service.env').read_text().splitlines():
    key,value=line.split('=',1); os.environ[key]=json.loads(value)
wal=Path(str(source)+"-wal")
size=source.stat().st_size+(wal.stat().st_size if wal.exists() else 0)
if shutil.disk_usage(root).free<2*size+256*1024*1024: raise SystemExit('Insufficient backup space; database retained; move backups off-server')
os.umask(0o077)
name=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
with tempfile.TemporaryDirectory(prefix='.backup-',dir=root) as temporary:
    snapshot=Path(temporary)/'pressure.sqlite3'
    with sqlite3.connect(source) as src, sqlite3.connect(snapshot) as dst:
        def progress(status,remaining,total):
            if shutil.disk_usage(root).free<256*1024*1024:
                raise RuntimeError('Stopped backup to preserve server free space')
        src.backup(dst,pages=256,progress=progress)
        if dst.execute('PRAGMA quick_check').fetchone()[0]!='ok': raise SystemExit('Backup integrity failure')
    target=root/(name+'.sqlite3.gz')
    with snapshot.open('rb') as src,gzip.open(target,'wb',compresslevel=1) as out: shutil.copyfileobj(src,out)
    # Encryption key is necessary for restoring device secrets and outbox.
    keyfile=root/'restore.env'
    with keyfile.open('w') as f: f.write('PRESSURE_KEY='+json.dumps(os.environ['PRESSURE_KEY'])+'\n')
for stale in sorted(root.glob('*.sqlite3.gz'))[:-2]: stale.unlink()
print('Verified compressed pressure backup:',target.name)
