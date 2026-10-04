import asyncio, logging, re, threading
from contextlib import asynccontextmanager
from pathlib import Path
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException
from .common import *
from . import auth, devices, measurements, grid, mail, registry
from .security import rate

@asynccontextmanager
async def lifespan(app):
    init(); cipher(); stop=threading.Event()
    worker=None
    if os.environ.get('PRESSURE_MAIL_FROM'):
        worker=threading.Thread(target=mail.work,args=(stop,),daemon=True); worker.start()
    yield
    stop.set()
    if worker: await asyncio.to_thread(worker.join,20)
app=FastAPI(title='Talajnyomás',version='1.0.0',root_path='/pressure_sensor',docs_url=None,redoc_url=None,openapi_url='/api/v1/openapi.json',lifespan=lifespan)

def error(request,status,code,message):
    return JSONResponse({'error':{'code':code,'message':message,'request_id':getattr(request.state,'request_id',uid())}},status_code=status,headers={'Retry-After':'60'} if status in (429,503) else {})
@app.exception_handler(HTTPException)
async def http_error(request,exc):
    d=exc.detail if isinstance(exc.detail,dict) else {'code':'http_error','message':str(exc.detail)}
    return error(request,exc.status_code,d['code'],d['message'])
@app.exception_handler(RequestValidationError)
async def validation(request,exc):
    if '/api/v1/admin/' in request.url.path:
        actor=getattr(request.state,'admin_account',None)
        if actor:
            records=exc.body if isinstance(exc.body,list) else [exc.body]
            ids=[p['device_id'] for p in records if isinstance(p,dict) and isinstance(p.get('device_id'),str) and re.fullmatch(r'hps-[0-9a-f]{12}',p['device_id'])]
            def record():
                with connect(True) as db: audit(db,actor,'invalid_admin_request',ids,outcome='invalid',request_id=request.state.request_id)
            await asyncio.to_thread(record)
        return error(request,422,'invalid_fields','Hibás import vagy paraméter. Egy gyártási rekord vagy 1–500 rekordból álló JSON-lista szükséges, érvényes eszközadatokkal.')
    return error(request,422,'invalid_fields','Hibás vagy hiányzó mező: '+', '.join('.'.join(map(str,x['loc'])) for x in exc.errors()[:8]))
@app.exception_handler(sqlite3.Error)
async def database_error(request,exc):
    logging.getLogger('pressure').warning('Database request failed: %s',type(exc).__name__)
    return error(request,503,'database_busy','A szolgáltatás átmenetileg nem elérhető.')
@app.middleware('http')
async def guard(request:Request,call_next):
    request.state.request_id=uid()
    try:
        if request.method not in ('GET','HEAD','OPTIONS'):
            if request.headers.get('origin') and request.headers['origin']!=auth.ORIGIN: fail(403,'origin')
            if request.headers.get('content-encoding','identity')!='identity': fail(415,'encoding_not_supported')
            data=bytearray()
            async for part in request.stream():
                data.extend(part)
                if len(data)>524288: fail(413,'body_too_large')
            request._body=bytes(data)
            path=request.url.path
            ip=request.client.host if request.client else 'unknown'
            if '/auth/' in path or '/device-claims/' in path:
                await asyncio.to_thread(rate,ip+':sensitive',30,300)
                # Independent email/account throttle prevents distributed email floods.
                try: email=obj(request._body).get('email','').strip().lower()
                except (ValueError,AttributeError): email=''
                if email: await asyncio.to_thread(rate,'email:'+digest(email),10,3600)
        response=await call_next(request)
    except HTTPException as exc: response=await http_error(request,exc)
    except sqlite3.Error as exc: response=await database_error(request,exc)
    response.headers['X-Request-ID']=request.state.request_id
    response.headers['Cache-Control']='no-store'
    response.headers['Referrer-Policy']='no-referrer'
    response.headers['X-Content-Type-Options']='nosniff'
    return response
for router in [auth.router,devices.router,measurements.router,grid.router,registry.router]: app.include_router(router)
@app.get('/api/v1/health')
def health():
    with connect() as db: one(db,'SELECT 1')
    return {'status':'ok','version':'1.0.0'}
WEB=Path(os.environ.get('PRESSURE_WEB',str(BASE.parent/'web')))
if WEB.is_dir(): app.mount('/',StaticFiles(directory=WEB,html=True),name='web')
