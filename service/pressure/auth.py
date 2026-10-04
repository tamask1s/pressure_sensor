import hmac
from urllib.parse import urlsplit
from fastapi import APIRouter, Depends, Request, Response
from .common import *
from .security import password_hash, password_ok, DUMMY
from .models import Credentials, Login, Email, Token, Reset, Refresh, Password

router=APIRouter(prefix='/api/v1')
COOKIE='pressure_session'
COOKIE_PATH=urlsplit(PUBLIC).path+'/'
ORIGIN=f'{urlsplit(PUBLIC).scheme}://{urlsplit(PUBLIC).netloc}'
def database(request:Request):
    with connect(request.method not in ('GET','HEAD','OPTIONS') or '/api/v1/admin/' in request.url.path) as db: yield db

def authenticated(request:Request, db=Depends(database, scope="function")):
    bearer=request.headers.get('authorization','')
    token=bearer[7:] if bearer.startswith('Bearer ') else request.cookies.get(COOKIE)
    if not token: fail(401,'login_required')
    a=one(db,'SELECT auth.*, accounts.email,accounts.verified FROM auth JOIN accounts ON accounts.id=auth.account WHERE access=?',(digest(token),))
    if not a or a['access_until']<now() or a['expires']<now(): fail(401,'login_required')
    if not a['verified']: fail(403,'email_unverified')
    if (a['kind']=='web') != (not bearer): fail(401,'wrong_token_kind')
    if a['kind']=='web' and request.method not in ('GET','HEAD'):
        if request.headers.get('origin')!=ORIGIN or not hmac.compare_digest(request.headers.get('x-csrf-token',''),a['csrf']): fail(403,'csrf')
    return a

def account(db,a): return {'id':a['account'],'email':a['email'],'is_admin':is_admin(db,a['account'])}
def queue_token(db,a,kind):
    token=random()
    db.execute('DELETE FROM tokens WHERE account=? AND kind=?',(a['id'],kind))
    db.execute('DELETE FROM outbox WHERE account=?',(a['id'],))
    db.execute('INSERT INTO tokens VALUES(?,?,?,?)',(digest(token),a['id'],kind,now()+(86400 if kind=='verify-email' else 3600)))
    link=f'{PUBLIC}/?action={kind}&token={token}'
    payload={'to':a['email'],'subject':'Talajminőség térképen – '+('e-mail megerősítése' if kind=='verify-email' else 'jelszó-visszaállítás'),'body':f'Nyisd meg ezt a hivatkozást:\n{link}\n\nHa nem te kérted, hagyd figyelmen kívül ezt a levelet.'}
    db.execute('INSERT INTO outbox(account,payload,next_try) VALUES(?,?,?)',(a['id'],seal(dump(payload)),now()))

@router.post('/auth/register',status_code=202)
def register(body:Credentials,db=Depends(database, scope="function")):
    email=body.email.strip().lower()
    if not one(db,'SELECT 1 FROM accounts WHERE email=?',(email,)):
        id=uid(); db.execute('INSERT INTO accounts(id,email,password) VALUES(?,?,?)',(id,email,password_hash(body.password)))
        queue_token(db,{'id':id,'email':email},'verify-email')
    return {'message':'Ha szükséges, elküldtük az e-mailt.'}
@router.post('/auth/resend-verification',status_code=202)
def resend(body:Email,db=Depends(database, scope="function")):
    a=one(db,'SELECT * FROM accounts WHERE email=?',(body.email.strip().lower(),))
    if a and not a['verified']: queue_token(db,a,'verify-email')
    return {'message':'Ha szükséges, elküldtük az e-mailt.'}
@router.post('/auth/forgot-password',status_code=202)
def forgot(body:Email,db=Depends(database, scope="function")):
    a=one(db,'SELECT * FROM accounts WHERE email=?',(body.email.strip().lower(),))
    if a and a['verified']: queue_token(db,a,'reset-password')
    return {'message':'Ha szükséges, elküldtük az e-mailt.'}
def use_token(db,token,kind):
    t=one(db,'SELECT * FROM tokens WHERE hash=? AND kind=? AND expires>?',(digest(token),kind,now()))
    if not t: fail(400,'invalid_token')
    db.execute('DELETE FROM tokens WHERE hash=?',(digest(token),))
    return t['account']
@router.post('/auth/verify-email',status_code=204)
def verify(body:Token,db=Depends(database, scope="function")):
    db.execute('UPDATE accounts SET verified=1 WHERE id=?',(use_token(db,body.token,'verify-email'),))
@router.post('/auth/reset-password',status_code=204)
def reset(body:Reset,db=Depends(database, scope="function")):
    id=use_token(db,body.token,'reset-password')
    db.execute('UPDATE accounts SET password=? WHERE id=?',(password_hash(body.new_password),id))
    db.execute('DELETE FROM auth WHERE account=?',(id,))

def issue(db,a,kind,response,auth_id=None):
    access,refresh,csrf=random(),random(),random()
    id=auth_id or uid(); expires=now()+30*86400
    if auth_id:
        old=one(db,'SELECT expires FROM auth WHERE id=?',(auth_id,)); expires=old['expires']
        db.execute('DELETE FROM auth WHERE id=?',(auth_id,))
    until=min(expires,now()+(900 if kind=='native' else 86400))
    db.execute('INSERT INTO auth VALUES(?,?,?,?,?,?,?,?)',(id,a['id'],kind,digest(access),digest(refresh) if kind=='native' else None,csrf,until,expires))
    result={'account':account(db,{'account':a['id'],'email':a['email']})}
    if kind=='native': result.update(access_token=access,refresh_token=refresh,expires_in=900)
    else: response.set_cookie(COOKIE,access,max_age=86400,httponly=True,secure=True,samesite='strict',path=COOKIE_PATH)
    return result
@router.post('/auth/login')
def login(body:Login,request:Request,response:Response,db=Depends(database, scope="function")):
    if body.client_kind=='web' and request.headers.get('origin')!=ORIGIN: fail(403,'origin')
    a=one(db,'SELECT * FROM accounts WHERE email=?',(body.email.strip().lower(),))
    valid=password_ok(body.password,a['password'] if a else DUMMY)
    if not a or not valid: fail(401,'invalid_credentials')
    if not a['verified']: fail(403,'email_unverified')
    return issue(db,a,body.client_kind,response)
@router.post('/auth/refresh')
def refresh(body:Refresh,response:Response,db=Depends(database, scope="function")):
    a=one(db,'SELECT auth.*,accounts.email FROM auth JOIN accounts ON accounts.id=auth.account WHERE refresh=? AND kind=? AND expires>?',(digest(body.refresh_token),'native',now()))
    if not a: fail(401,'invalid_refresh')
    return issue(db,{'id':a['account'],'email':a['email']},'native',response,a['id'])
@router.get('/auth/session')
def session(a=Depends(authenticated),db=Depends(database, scope="function")):
    return {'account':account(db,a),'csrf_token':a['csrf'] if a['kind']=='web' else None,'expires_at':iso(a['access_until'])}
@router.post('/auth/logout',status_code=204)
def logout(response:Response,a=Depends(authenticated),db=Depends(database, scope="function")):
    db.execute('DELETE FROM auth WHERE id=?',(a['id'],)); response.delete_cookie(COOKIE,path=COOKIE_PATH)
@router.delete('/account',status_code=204)
def delete_account(body:Password,response:Response,a=Depends(authenticated),db=Depends(database, scope="function")):
    owner=one(db,'SELECT * FROM accounts WHERE id=?',(a['account'],))
    if not password_ok(body.password,owner['password']): fail(401,'invalid_credentials')
    db.execute('UPDATE devices SET account=NULL,ownership=NULL,retired=1 WHERE account=?',(a['account'],))
    db.execute('DELETE FROM accounts WHERE id=?',(a['account'],))
    response.delete_cookie(COOKIE,path=COOKIE_PATH)
