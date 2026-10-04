"""Verify a GitHub Actions web artifact and stage it without installing Flutter."""
import argparse, hashlib, shutil, tempfile, zipfile
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('archive',type=Path)
p.add_argument('sha256',help='Expected digest from the GitHub artifact API')
args=p.parse_args()
if hashlib.sha256(args.archive.read_bytes()).hexdigest()!=args.sha256.split(':')[-1]:
    raise SystemExit('Artifact digest mismatch')
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='pressure-web-',dir=root) as folder:
    stage=Path(folder)
    with zipfile.ZipFile(args.archive) as z:
        for name in z.namelist():
            try: (stage/name).resolve().relative_to(stage)
            except ValueError: raise SystemExit('Invalid artifact path') from None
        z.extractall(stage)
    html=(stage/'index.html').read_text()
    if '<base href="/pressure_sensor/">' not in html: raise SystemExit('Incorrect web base path')
    if 'name="referrer" content="strict-origin"' not in html: raise SystemExit('Incorrect referrer policy')
    if '/pressure_sensor/api/v1' not in (stage/'main.dart.js').read_text(): raise SystemExit('Incorrect API path')
    target=root/'web'
    if target.exists(): shutil.rmtree(target)
    shutil.copytree(stage,target)
    # TemporaryDirectory is 0700; the deployed service user must read the web.
    target.chmod(0o755)
print('Verified web artifact staged in service/web')
