#!/usr/bin/env python3
"""Run with sudo after tests. Changes only pressure paths and the apex routing exception."""
import hashlib, json, os, pwd, re, shlex, shutil, subprocess, sys, time
from pathlib import Path
SOURCE=Path(__file__).resolve().parents[2]
def run(*args,**kw): return subprocess.run(args,check=True,**kw)
def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
if os.geteuid()!=0: raise SystemExit('Run with sudo')
protected=[Path('/etc/nginx/timeonion-services/mesemondo.conf'),Path('/etc/nginx/timeonion-services/synsigra.conf')]
protected=[p for p in Path('/etc/nginx/timeonion-services').glob('*') if p.name!='pressure_sensor.conf']+[Path('/etc/systemd/system/mesemondo.service'),Path('/etc/systemd/system/mesemondo-postgresql.service')]
before={str(p):digest(p) for p in protected if p.is_file()}
try: pwd.getpwnam('pressure-sensor')
except KeyError: run('useradd','--system','--home-dir','/var/lib/pressure_sensor','--shell','/usr/sbin/nologin','pressure-sensor')
for path in ['/opt/pressure_sensor','/etc/pressure_sensor','/var/lib/pressure_sensor','/var/backups/pressure_sensor']:
    Path(path).mkdir(parents=True,exist_ok=True)
run('chown','pressure-sensor:pressure-sensor','/var/lib/pressure_sensor')
os.chmod('/var/lib/pressure_sensor',0o700); os.chmod('/etc/pressure_sensor',0o750)
run('chown','root:pressure-sensor','/etc/pressure_sensor')
release=Path('/opt/pressure_sensor/releases')/time.strftime('%Y%m%d-%H%M%S'); release.mkdir(parents=True)
shutil.copytree(SOURCE/'service',release/'service',ignore=shutil.ignore_patterns('.deps','.runtime','__pycache__','.pytest_cache','tests'))
if not Path('/opt/pressure_sensor/deps/pyproj').exists(): shutil.copytree(SOURCE/'service/.deps','/opt/pressure_sensor/deps',dirs_exist_ok=True)
# Reuse the running application's SMTP settings, but copy the credential to a
# pressure-only readable file. No cross-service credential-file permissions change.
env=Path('/etc/pressure_sensor/service.env')
if not env.exists():
    config={}
    for line in Path('/usr/local/apache2/conf/extra/syn_sig_ra_email.conf').read_text().splitlines():
        fields=shlex.split(line,comments=True)
        if len(fields)>=2: config[fields[0]]=fields[1]
    from urllib.parse import urlsplit
    smtp=urlsplit(config['SynSigRaEmailSmtpUrl'])
    if smtp.scheme!='smtp': raise SystemExit('Expected SMTP+STARTTLS configuration')
    credential=Path('/etc/pressure_sensor/smtp-password')
    shutil.copyfile(config['SynSigRaEmailSmtpPasswordFile'],credential); os.chmod(credential,0o640); run('chown','root:pressure-sensor',str(credential))
    key=subprocess.check_output(['/opt/mesemondo/venv/bin/python','-c','from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'],text=True).strip()
    values={'PRESSURE_DB':'/var/lib/pressure_sensor/pressure.sqlite3','PRESSURE_PUBLIC_URL':'https://timeonion.com/pressure_sensor','PRESSURE_WEB':'/opt/pressure_sensor/current/service/web','PRESSURE_KEY':key,'PRESSURE_MAIL_FROM':config['SynSigRaEmailFrom'],'PRESSURE_SMTP_HOST':smtp.hostname,'PRESSURE_SMTP_PORT':str(smtp.port or 587),'PRESSURE_SMTP_TLS':'1','PRESSURE_SMTP_USER':config['SynSigRaEmailSmtpUsername'],'PRESSURE_SMTP_PASSWORD_FILE':str(credential)}
    fd=os.open(env,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o640)
    with os.fdopen(fd,'w') as f:
        for k,v in values.items(): f.write(k+'='+json.dumps(v)+'\n')
    run('chown','root:pressure-sensor',str(env))
current=Path('/opt/pressure_sensor/current'); previous=os.readlink(current) if current.is_symlink() else None
link=Path('/opt/pressure_sensor/next'); link.symlink_to(release); link.replace(current)
shutil.copyfile(SOURCE/'service/ops/pressure_sensor.service','/etc/systemd/system/pressure_sensor.service')
run('systemctl','daemon-reload'); run('systemctl','enable','--now','pressure_sensor.service')
if previous: run('systemctl','restart','pressure_sensor.service')
import urllib.request
for i in range(30):
    try:
        assert json.load(urllib.request.urlopen('http://127.0.0.1:8093/api/v1/health',timeout=2))['status']=='ok'; break
    except Exception: time.sleep(1)
else: raise SystemExit('Pressure health check failed; nginx untouched')
nginx=Path('/etc/nginx/sites-available/timeonion.conf'); original=nginx.read_text()
backup=Path('/etc/pressure_sensor/nginx-before.conf')
if not backup.exists(): backup.write_text(original)
marker='    return 301 https://www.timeonion.com$request_uri;\n}\n\nserver {'
replacement='    include /etc/nginx/timeonion-services/pressure_sensor.conf;\n    location / { return 301 https://www.timeonion.com$request_uri; }\n}\n\nserver {'
if 'include /etc/nginx/timeonion-services/pressure_sensor.conf;' not in original:
    if original.count(marker)!=1: raise SystemExit('Unexpected nginx structure; no modification')
    nginx.write_text(original.replace(marker,replacement))
snippet=Path('/etc/nginx/timeonion-services/pressure_sensor.conf'); old_snippet=snippet.read_bytes() if snippet.exists() else None
shutil.copyfile(SOURCE/'service/ops/nginx.conf',snippet)
try:
    run('nginx','-t')
    assert all(digest(p)==h for p,h in before.items())
    run('systemctl','reload','nginx')
except BaseException:
    nginx.write_text(original)
    if old_snippet is None: snippet.unlink()
    else: snippet.write_bytes(old_snippet)
    raise
Path('/etc/pressure_sensor/protected-hashes.json').write_text(json.dumps(before,indent=2))
for name in ['pressure_sensor-backup.service','pressure_sensor-backup.timer']:
    shutil.copyfile(SOURCE/'service/ops'/name,'/etc/systemd/system/'+name)
run('systemctl','daemon-reload')
run('systemctl','enable','--now','pressure_sensor-backup.timer')
print('Deployed',release,'https://timeonion.com/pressure_sensor/')
