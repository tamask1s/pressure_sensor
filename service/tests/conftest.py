import os, sys, tempfile
from pathlib import Path
from cryptography.fernet import Fernet
os.environ['PRESSURE_KEY']=Fernet.generate_key().decode()
os.environ['PRESSURE_DB']=tempfile.mktemp(prefix='pressure-tests-',suffix='.sqlite3')
os.environ['PRESSURE_PUBLIC_URL']='https://testserver/pressure_sensor'
os.environ.pop('PRESSURE_MAIL_FROM',None)
sys.path.insert(0,str(Path(__file__).parents[1]))
import pytest
from fastapi.testclient import TestClient
from pressure import common
from pressure.api import app
@pytest.fixture
def client(tmp_path,monkeypatch):
    path=str(tmp_path/'test.sqlite3'); monkeypatch.setattr(common,'DB',path)
    import pressure.measurements as m
    monkeypatch.setattr(m,'DB',path)
    common.init()
    with TestClient(app,base_url='https://testserver') as c: yield c
