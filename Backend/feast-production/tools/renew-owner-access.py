#!/usr/bin/env python3
"""One-shot owner-only code/hash renewal. No production/ledger/settings/provider writes."""
import copy,datetime,hashlib,os,importlib.util,json,pathlib,re,resource,sys
spec=importlib.util.spec_from_file_location('preservation',pathlib.Path(__file__).with_name('update-production-code.py'));p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p);u=p.u
OWNER_SHA='eab007d306f0d5306596435254b52a7fc554d5f4d349957fcd90d40cb0e5b55d'
ROOT=pathlib.Path('/tmp/feast-owner-renewal-reviewed');EXPECTED={p.PRODUCTION:'42ebc015-db1a-4a48-9ad7-03db5a167fd8',p.OWNER:'45e8a5c6-5412-4467-bb09-58ff81ecf4da'}
def record(raw,now=None):
 now=now or datetime.datetime.now(datetime.timezone.utc);v=json.loads(raw)
 if not isinstance(v,list) or len(v)!=1:raise u.SafeStop('record count')
 r=v[0]
 if set(r)!={'id','sha256','createdAt','expiresAt'} or r['id']!='owner-original-iphone17' or not re.fullmatch('[a-f0-9]{64}',r['sha256']):raise u.SafeStop('record identity')
 start=datetime.datetime.fromisoformat(r['createdAt'].replace('Z','+00:00'));end=datetime.datetime.fromisoformat(r['expiresAt'].replace('Z','+00:00'))
 if not start<=now<end or end-start!=datetime.timedelta(days=30) or now-start>datetime.timedelta(hours=2):raise u.SafeStop('record expiry')
 return v
class OwnerAPI(u.API):
 def request(self,method,name,*args,**kwargs):
  if method!='GET' and name!=p.OWNER:raise u.SafeStop('production mutation forbidden')
  return super().request(method,name,*args,**kwargs)
def run(api,root=ROOT,pause=p.time.sleep):
 u.reviewed.inspect(root)
 script=(root/'owner/worker.js').read_bytes()
 if hashlib.sha256(script).hexdigest()!=OWNER_SHA:raise u.SafeStop('module drift')
 records=record((root/'owner-hash.json').read_text());receipt=root/'renewal-receipt.json'
 state={'state':'preflight','requests':[],'providerCalls':0,'ledgerWrites':0,'productionWrites':0,'expectedVersions':EXPECTED,'expiresAt':records[0]['expiresAt'],'stagedVersion':None}
 with receipt.open('x') as f:
  os.fchmod(f.fileno(),0o600);f.write(u.canonical(state));f.flush();os.fsync(f.fileno())
 def save():u.atomic_receipt(receipt,state)
 def event(e):state['requests'].append({k:e[k] for k in ['method','worker','path','status','cloudflareErrorCodes']});save()
 api.on_event=event;wrote=False
 try:
  before={n:p.snapshot(api,n,v) for n,v in EXPECTED.items()}
  meta=u.metadata(before[p.OWNER]);meta['bindings']=[x for x in meta['bindings'] if x['name']!='OWNER_TOKEN_HASHES_JSON']+[{'name':'OWNER_TOKEN_HASHES_JSON','type':'secret_text','text':u.canonical(records)}]
  for n,v in EXPECTED.items():u.same_configuration(before[n],p.snapshot(api,n,v))
  body,mime=u.multipart(meta,script);state['state']='upload-intent';save();wrote=True
  result=api.request('POST',p.OWNER,'/versions?bindings_inherit=strict',body,mime);new=u.checked_upload(result,meta);state['stagedVersion']=new;save()
  p.wait_version(lambda:u.latest(api,p.OWNER),EXPECTED[p.OWNER],new,pause)
  detail=api.request('GET',p.OWNER,'/versions/'+new)
  staged={'resources':p.resources(p.OWNER,detail),'settings':u.checked_settings(api.request('GET',p.OWNER,'/script-settings'))}
  u.same_configuration(before[p.OWNER],staged)
  u.same_configuration(before[p.PRODUCTION],p.snapshot(api,p.PRODUCTION,EXPECTED[p.PRODUCTION]))
  u.same_configuration(before[p.OWNER],p.snapshot(api,p.OWNER,EXPECTED[p.OWNER],new))
  state['state']='activation-intent';save()
  api.request('POST',p.OWNER,'/deployments',u.canonical({'strategy':'percentage','versions':[{'version_id':new,'percentage':100}]}).encode(),'application/json')
  p.wait_version(lambda:u.active(api,p.OWNER),EXPECTED[p.OWNER],new,pause)
  u.same_configuration(before[p.OWNER],p.snapshot(api,p.OWNER,new));u.same_configuration(before[p.PRODUCTION],p.snapshot(api,p.PRODUCTION,EXPECTED[p.PRODUCTION]))
  u.same_configuration(before[p.OWNER],p.snapshot(api,p.OWNER,new))
  state.update(state='verified-owner-renewal',ownerVersion=new,preservationVerified=True);save();return True
 except BaseException as e:
  state.update(state='uncertain-reconcile-before-retry' if wrote else 'preflight-stopped-no-write',failureType=type(e).__name__)
  if isinstance(e,u.SafeStop):state['validationCode']=str(e)
  try:save()
  except OSError:pass
  return False
if __name__=='__main__':
 resource.setrlimit(resource.RLIMIT_CORE,(0,0));token='';api=None
 try:
  token=sys.stdin.buffer.read(202).decode().strip()
  if not re.fullmatch('[A-Za-z0-9_-]{20,200}',token):raise u.SafeStop('credential format')
  api=OwnerAPI(token);ok=run(api);print('Owner renewal server update verified.' if ok else 'STOP: inspect renewal receipt; no automatic retry.');sys.exit(0 if ok else 1)
 finally:
  if api:api.token=''
  token=''
