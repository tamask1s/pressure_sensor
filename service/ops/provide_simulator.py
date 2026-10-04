"""Prepare a private local-test bundle for the repository owner."""
import os,pwd,subprocess,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]; dest=root/'.runtime'; dest.mkdir(exist_ok=True)
profile=dest/'simulator-profile.json'
if not profile.exists(): subprocess.run(['bash','/opt/pressure_sensor/current/service/ops/admin.sh','simulator-profile',str(profile),'--pairs','2'],check=True)
readme='''1. Regisztrálj: https://timeonion.com/pressure_sensor/\n2. Erősítsd meg az e-mailt.\n3. Python 3-mal futtasd:\n   python simulator.py --email SAJAT_EMAIL --profile simulator-profile.json --seconds 60\nA jelszót külön bekéri. Ne oszd meg a profilfájlt.\nA SZIMULÁTOR mérések az Előzmények és Térkép nézetben lesznek.\nEz HTTP-szimulátor, nem BLE-emulátor.\n'''
bundle=dest/'pressure-simulator.zip'
with zipfile.ZipFile(bundle,'w',zipfile.ZIP_DEFLATED) as z:
    z.write(root/'simulator.py','simulator.py'); z.write(profile,'simulator-profile.json'); z.writestr('OLVASS_EL.txt',readme)
user=pwd.getpwnam('graphyt2')
for path in [profile,bundle]: os.chmod(path,0o600); os.chown(path,user.pw_uid,user.pw_gid)
print('Private simulator bundle:',bundle)
