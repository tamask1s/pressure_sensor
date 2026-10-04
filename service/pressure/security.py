"""Use the host's Argon2 library: no second password/crypto stack to install."""
import ctypes, ctypes.util, hmac, os
from .common import *
lib=ctypes.CDLL(ctypes.util.find_library('argon2'))
lib.argon2id_hash_encoded.argtypes=[ctypes.c_uint32,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_size_t]
lib.argon2id_verify.argtypes=[ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t]
def password_hash(value):
    value=value.encode(); salt=os.urandom(16); out=ctypes.create_string_buffer(256)
    if lib.argon2id_hash_encoded(2,19456,1,value,len(value),salt,len(salt),32,out,len(out)): raise RuntimeError('argon2')
    return out.value.decode()
def password_ok(value,hashed):
    value=value.encode()
    return lib.argon2id_verify(hashed.encode(),value,len(value))==0
DUMMY=password_hash(random())
def claim_proof(secret,c):
    message=f"HPS-CLAIM-v1\n{c['device']}\n{c['account']}\n{c['id']}\n".encode()+base64.urlsafe_b64decode(c['nonce']+'==')
    return b64(hmac.digest(bytes.fromhex(secret),message,'sha256'))
def rate(key,maximum,seconds):
    window=int(now()//seconds)
    with connect(True) as db:
        db.execute('DELETE FROM limits WHERE window < ? AND key LIKE ?', (window-2,f'{seconds}:%'))
        key=f'{seconds}:{key}'
        db.execute('INSERT INTO limits VALUES(?,?,1) ON CONFLICT(key) DO UPDATE SET count=CASE WHEN window=excluded.window THEN count+1 ELSE 1 END,window=excluded.window',(key,window))
        count=one(db,'SELECT count FROM limits WHERE key=?',(key,))['count']
    if count>maximum: fail(429,'rate_limited','Túl sok kérés, próbáld újra később.')
