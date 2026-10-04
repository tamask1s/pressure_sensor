import base64, hashlib, json, os, secrets, sqlite3, time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4
from cryptography.fernet import Fernet
from fastapi import HTTPException

BASE = Path(__file__).parent
DB = os.environ.get('PRESSURE_DB', '/var/lib/pressure_sensor/pressure.sqlite3')
PUBLIC = os.environ.get('PRESSURE_PUBLIC_URL', 'https://timeonion.com/pressure_sensor').rstrip('/')
KEY = os.environ.get('PRESSURE_KEY', '')
def cipher(): return Fernet(KEY.encode())
def seal(value): return cipher().encrypt(value.encode()).decode()
def unseal(value): return cipher().decrypt(value.encode()).decode()
def dump(value):
    if hasattr(value, 'model_dump'): value=value.model_dump(mode='json')
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)
def obj(value): return json.loads(value)
def now(): return time.time()
def iso(t): return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
def epoch(v): return datetime.fromisoformat(v.replace('Z','+00:00')).timestamp()
def uid(): return str(uuid4())
def random(): return secrets.token_urlsafe(32)
def digest(v): return hashlib.sha256(v.encode()).hexdigest()
def b64(v): return base64.urlsafe_b64encode(v).decode().rstrip('=')
def fail(status, code, message=None): raise HTTPException(status, {'code':code,'message':message or code})
def init():
    with sqlite3.connect(DB) as db: db.executescript((BASE/'schema.sql').read_text())
@contextmanager
def connect(write=False):
    db=sqlite3.connect(DB,timeout=10,isolation_level=None,check_same_thread=False)
    db.row_factory=sqlite3.Row
    db.execute('PRAGMA foreign_keys=ON')
    db.execute('PRAGMA synchronous=FULL')
    db.execute('PRAGMA cache_size=-4096')
    db.execute('BEGIN IMMEDIATE' if write else 'BEGIN')
    # Bound pathological queries without allocating unbounded result sets.
    until=time.monotonic()+20
    db.set_progress_handler(lambda: int(time.monotonic()>until),10000)
    try:
        yield db
        db.commit()
    except BaseException:
        db.rollback()
        raise
    finally: db.close()
def one(db,sql,args=()): return db.execute(sql,args).fetchone()
def owned(db,table,id,account):
    assert table in ('sessions','devices','rigs','claims')
    row=one(db,f'SELECT * FROM {table} WHERE id=? AND account=?',(id,account))
    if not row: fail(404,'not_found')
    return row
