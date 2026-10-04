"""Rebase the verified, prebuilt upstream web artifact without installing Flutter."""
from pathlib import Path
import hashlib, zipfile
root=Path(__file__).resolve().parents[1]
archive=Path('/tmp/pressure-web.zip')
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='4408cb92b76b9d7cb6ad5ce4dc8cfe4b1faaa252fffd22f2698daa8ce723c3b8'
with zipfile.ZipFile(archive) as z: z.extractall(root/'web')
p=root/'web/index.html'; s=p.read_text(); assert '<base href="/">' in s; p.write_text(s.replace('<base href="/">','<base href="/pressure_sensor/">').replace('name="referrer" content="no-referrer"','name="referrer" content="strict-origin"'))
p=root/'web/main.dart.js'; s=p.read_text(); assert s.count('"/api/v1"')==1; p.write_text(s.replace('"/api/v1"','"/pressure_sensor/api/v1"'))
