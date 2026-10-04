"""Manufacturer registry. Customer ownership still requires the BLE/HMAC claim."""
from typing import Annotated, Literal
from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse
from pydantic import Field
from .common import *
from .auth import authenticated, database
from .admin import provision, same_provision
from .models import Provision, DeviceID, Model

router=APIRouter(prefix='/api/v1/admin',tags=['Admin device registry'])
ImportBody=Provision | Annotated[list[Provision],Field(min_length=1,max_length=500)]

class Owner(Model):
    account_id: str
    email: str
class RegistryDevice(Model):
    device_id: DeviceID
    status: Literal['registered','paired','retired']
    owner: Owner | None
    sensor_serial: int
    protocol_version: int
    firmware_version: str | None
class RegistryPage(Model):
    items: list[RegistryDevice]
    next_cursor: DeviceID | None
class ImportItem(Model):
    device_id: DeviceID
    status: Literal['new','unchanged','conflict']
class ImportCounts(Model):
    new: int
    unchanged: int
    conflict: int
class ImportResult(Model):
    dry_run: bool
    valid: bool
    received: int
    unique: int
    counts: ImportCounts
    items: list[ImportItem]

def administrator(request:Request,a=Depends(authenticated),db=Depends(database,scope='function')):
    if not is_admin(db,a['account']): fail(403,'admin_required','Ehhez adminisztrátori jogosultság szükséges.')
    request.state.admin_account=a['account']
    return a

@router.get('/devices',response_model=RegistryPage,summary='List all manufactured devices and their current owners')
def devices(request:Request,q:Annotated[str,Query(max_length=32,pattern=r'^[a-zA-Z0-9-]*$')]='',
            cursor:DeviceID|None=None,limit:Annotated[int,Query(ge=1,le=200)]=50,
            a=Depends(administrator),db=Depends(database,scope='function')):
    rows=db.execute('SELECT d.id,d.metadata,d.account,d.retired,a.email FROM devices d LEFT JOIN accounts a ON a.id=d.account WHERE d.id LIKE ? AND d.id>? ORDER BY d.id LIMIT ?',
        ('%'+q.lower()+'%',cursor or '',limit+1)).fetchall()
    items=[]
    for row in rows[:limit]:
        meta=obj(row['metadata'])
        items.append({'device_id':row['id'],'status':'retired' if row['retired'] else ('paired' if row['account'] else 'registered'),
            'owner':{'account_id':row['account'],'email':row['email']} if row['account'] else None,
            'sensor_serial':meta['sensor_serial'],'protocol_version':meta['protocol_version'],'firmware_version':meta.get('firmware_version')})
    audit(db,a['account'],'list_devices',[d['device_id'] for d in items],request_id=request.state.request_id)
    return {'items':items,'next_cursor':items[-1]['device_id'] if len(rows)>limit else None}

@router.post('/devices/import',response_model=ImportResult,summary='Validate or atomically import up to 500 manufacturing records',
    description='Accepts one provisioning record or a bare JSON list. Default dry_run=true changes no devices. Identical records are unchanged, conflicting metadata or keys reject the whole batch. Import never assigns an owner.',
    responses={409:{'description':'Conflicting device; no devices changed'},422:{'description':'Invalid batch; no devices changed'},403:{'description':'Admin role or web CSRF check failed'}})
def import_devices(body:ImportBody,request:Request,dry_run:bool=True,
                   a=Depends(administrator),db=Depends(database,scope='function')):
    records=body if isinstance(body,list) else [body]
    unique={}; statuses={}
    for p in records:
        id=p.device_id
        if id in unique:
            if dump(unique[id])!=dump(p): statuses[id]='conflict'
            continue
        unique[id]=p
        existing=one(db,'SELECT secret,metadata FROM devices WHERE id=?',(id,))
        statuses[id]='new' if not existing else ('unchanged' if same_provision(existing,p) else 'conflict')
    valid='conflict' not in statuses.values()
    result={'dry_run':dry_run,'valid':valid,'received':len(records),'unique':len(unique),
        'counts':{s:list(statuses.values()).count(s) for s in ('new','unchanged','conflict')},
        'items':[{'device_id':id,'status':s} for id,s in statuses.items()]}
    if valid and not dry_run:
        for id,p in unique.items():
            if statuses[id]=='new': provision(db,p)
    audit(db,a['account'],'preview_import' if dry_run else 'import_devices',unique,
        outcome='ok' if valid else 'conflict',request_id=request.state.request_id)
    if not valid and not dry_run:
        result['error']={'code':'import_conflict','message':'Eltérő kulcs vagy adat tartozik egy eszközazonosítóhoz. Semmit nem importáltunk.','request_id':request.state.request_id}
        # Return normally so the audit commits; preflight made no device changes.
        return JSONResponse(result,status_code=409)
    return result
