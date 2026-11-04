#!/usr/bin/env python3
"""One-shot code-only update of TWO existing OFF Workers. Default is offline inspection.
Never creates resources/credentials, changes flags, migrates storage, or calls a provider.
"""
import argparse,copy,getpass,hashlib,importlib.util,json,pathlib,re,resource,sys,traceback,urllib.request,urllib.error,uuid,warnings,os,tempfile,time
spec=importlib.util.spec_from_file_location('reviewed',pathlib.Path(__file__).with_name('deploy-reviewed.py'))
reviewed=importlib.util.module_from_spec(spec);spec.loader.exec_module(reviewed)
EXPECTED={'feast-proxy-production':'7fee5f68-f1de-4e20-a4c5-90d666d48474','feast-owner-validation':'93fcc415-ae0a-435d-9849-87041f07b79e'}
NAMESPACE='76d22b61e02d48cf9723208b91b2cd4b'
BASE='https://api.cloudflare.com/client/v4/accounts/'+reviewed.ACCOUNT+'/workers/scripts/'
RUNTIME_KEYS={'compatibility_date','compatibility_flags','limits','usage_model','exports','migration_tag'}
class SafeStop(ValueError):
 pass
def canonical(v):return json.dumps(v,sort_keys=True,separators=(',',':'))
def fingerprint(v):return hashlib.sha256(canonical(v).encode()).hexdigest()
def version_id(v):
 if not isinstance(v,str) or not re.fullmatch('[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}',v):raise SafeStop('invalid version')
 return v
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args,**kwargs):return None
class API:
 def __init__(self,token):self.token=token;self.opener=urllib.request.build_opener(NoRedirect());self.on_event=lambda event:None
 def request(self,method,name,suffix='',body=None,content_type=None):
  if name not in EXPECTED or method not in ['GET','POST']:raise SafeStop('wrong API scope')
  if method=='POST' and suffix not in ['/versions?bindings_inherit=strict','/deployments']:raise SafeStop('mutation forbidden')
  headers={'Authorization':'Bearer '+self.token,'Accept':'application/json'}
  if content_type:headers['Content-Type']=content_type
  request=urllib.request.Request(BASE+name+suffix,data=body,headers=headers,method=method)
  # Record ONLY endpoint/method/status/numeric errors. Never headers, input or raw bodies.
  event={'method':method,'worker':name,'path':'/accounts/'+reviewed.ACCOUNT+'/workers/scripts/'+name+suffix,'status':None,'cloudflareErrorCodes':[]}
  def codes(value):
   if not isinstance(value,dict):return []
   errors=value.get('errors')
   if not isinstance(errors,list):return []
   return [x['code'] for x in errors if isinstance(x,dict) and isinstance(x.get('code'),int) and not isinstance(x['code'],bool)][:10]
  try:
   with self.opener.open(request,timeout=60) as response:
    event['status']=response.status;raw=response.read(1048577)
    if len(raw)>1048576:raise SafeStop('metadata response too large')
    value=json.loads(raw);event['cloudflareErrorCodes']=codes(value)
    if suffix=='/script-settings' and isinstance(value,dict):
     result=value.get('result');event['resultShape']={'resultType':type(result).__name__}
     if isinstance(result,dict):event['resultShape']['fieldTypes']={k:type(result.get(k)).__name__ for k in ['logpush','observability','tags','tail_consumers']}
    if suffix.startswith('/versions/') and isinstance(value,dict):
     result=value.get('result');resources=result.get('resources') if isinstance(result,dict) else None
     event['resultShape']={'resultType':type(result).__name__,'resourcesType':type(resources).__name__}
     if isinstance(resources,dict):
      event['resultShape']['fieldTypes']={k:type(resources.get(k)).__name__ for k in ['bindings','script','script_runtime']}
      runtime=resources.get('script_runtime')
      if isinstance(runtime,dict):event['resultShape']['runtimeFieldTypes']={k:type(runtime.get(k)).__name__ for k in sorted(RUNTIME_KEYS)}
    if suffix=='/versions' and isinstance(value,dict):
     result=value.get('result');items=result.get('items') if isinstance(result,dict) else result
     event['resultShape']={'resultType':type(result).__name__,'itemsType':type(items).__name__,'count':len(items) if isinstance(items,list) else None,'firstItemType':type(items[0]).__name__ if isinstance(items,list) and items else None}
   if not isinstance(value,dict) or value.get('success') is not True or 'result' not in value:raise SafeStop('API response unverified')
   return value['result']
  except urllib.error.HTTPError as error:
   event['status']=error.code
   try:
    raw=error.read(65537)
    if len(raw)<=65536:event['cloudflareErrorCodes']=codes(json.loads(raw))
   except Exception:pass
   raise
  finally:
   # Preserve the original API failure if journaling also fails; either way stop.
   original=sys.exc_info()[0]
   try:self.on_event(event)
   except OSError:
    if original is None:raise

def list_items(result,key):
 items=result.get(key) if isinstance(result,dict) else result
 if not isinstance(items,list) or not items or any(not isinstance(x,dict) for x in items):raise SafeStop('unverified list shape')
 return items
def active(api,name):
 deployments=list_items(api.request('GET',name,'/deployments'),'deployments')
 versions=deployments[0].get('versions')
 if not isinstance(versions,list) or len(versions)!=1 or not isinstance(versions[0],dict) or versions[0].get('percentage')!=100:raise SafeStop('split deployment')
 return version_id(versions[0].get('version_id'))
def latest(api,name):
 items=list_items(api.request('GET',name,'/versions'),'items')
 ids=[version_id(v.get('id')) for v in items]
 if len(ids)!=len(set(ids)):raise SafeStop('duplicate version metadata')
 # Documented API order: first item is latest. number/metadata are optional;
 # never sort nullable numbers or assume an arbitrary wrapper is a version list.
 first_number=items[0].get('number')
 for item in items:
  number=item.get('number')
  if number is not None and (not isinstance(number,int) or isinstance(number,bool)):raise SafeStop('invalid version number')
  if first_number is not None and number is not None and number>first_number:raise SafeStop('version order mismatch')
 return ids[0]
def binding_view(bindings):
 if not isinstance(bindings,list) or not bindings:raise SafeStop('bindings unavailable')
 result={}
 for b in bindings:
  if not isinstance(b,dict) or not isinstance(b.get('name'),str) or b['name'] in result:raise SafeStop('binding shape')
  if b.get('type') not in ['plain_text','json','secret_text','durable_object_namespace','service']:raise SafeStop('unreviewed binding type')
  if b['type']=='secret_text' and set(b)!={'type','name'}:raise SafeStop('unexpected secret material')
  result[b['name']]=copy.deepcopy(b)
 return result
def checked_resources(name,detail):
 if not isinstance(detail,dict) or not isinstance(detail.get('resources'),dict):raise SafeStop('unreviewed resource shape')
 resources=copy.deepcopy(detail['resources'])
 if not isinstance(resources.get('script'),dict):raise SafeStop('unreviewed script metadata')
 if set(resources)!={'bindings','script','script_runtime'}:raise SafeStop('unreviewed resource shape')
 bindings=binding_view(resources['bindings']);variables={k:v.get('text') for k,v in bindings.items() if v['type']=='plain_text'}
 if variables.get('LIVE_AI')!='false':raise SafeStop('dispatch must be OFF')
 for key in ['ALLOW_PUBLIC_LOOKUP','ALLOW_RECONCILED_BUDGET','ALLOW_LEGACY_RECONCILIATION']:
  if key in variables and variables[key]!='false':raise SafeStop('feature must be OFF')
 if name=='feast-proxy-production':
  if variables.get('ENVIRONMENT')!='production' or variables.get('ENABLED')!='false' or variables.get('OWNER_VALIDATION_ENABLED')!='true':raise SafeStop('production gate drift')
  b=bindings.get('PRODUCTION_STATE',{})
  if b.get('type')!='durable_object_namespace' or b.get('namespace_id')!=NAMESPACE or b.get('class_name','ProductionLedger')!='ProductionLedger':raise SafeStop('namespace drift')
  if bindings.get('OPENAI_API_KEY',{}).get('type')!='secret_text':raise SafeStop('missing provider secret')
 else:
  if variables.get('ENABLED')!='true':raise SafeStop('owner gate drift')
  b=bindings.get('PRODUCTION',{})
  if b.get('type')!='service' or b.get('service')!='feast-proxy-production' or b.get('entrypoint')!='OwnerValidationRPC':raise SafeStop('private RPC drift')
  if bindings.get('OWNER_TOKEN_HASHES_JSON',{}).get('type')!='secret_text':raise SafeStop('missing owner hash')
 runtime=resources['script_runtime']
 if not isinstance(runtime,dict) or set(runtime)-RUNTIME_KEYS or runtime.get('compatibility_date')!='2026-10-20':raise SafeStop('unreviewed runtime')
 if runtime.get('migration_tag') not in [None,'production-v1']:raise SafeStop('migration drift')
 # Canonicalize only known optional null/empty runtime fields. Never infer flags,
 # identity, namespace, usage mode or a custom limit from missing values.
 if runtime.get('compatibility_flags') is None:runtime['compatibility_flags']=[]
 if runtime.get('exports') is None:runtime['exports']={}
 for optional in ['limits','migration_tag','usage_model']:
  if runtime.get(optional) is None:runtime.pop(optional,None)
 exports=runtime.get('exports')
 if exports is None:exports={}
 if not isinstance(exports,dict):raise SafeStop('unreviewed exports metadata')
 flags=runtime.get('compatibility_flags')
 if flags is not None and (not isinstance(flags,list) or any(not isinstance(x,str) for x in flags)):raise SafeStop('unreviewed runtime flags')
 limits=runtime.get('limits')
 if limits is not None and (not isinstance(limits,dict) or set(limits)-{'cpu_ms'} or any(not isinstance(v,int) or isinstance(v,bool) or v<=0 for v in limits.values())):raise SafeStop('unreviewed runtime limits')
 if runtime.get('usage_model') not in [None,'standard','bundled','unbound']:raise SafeStop('unreviewed usage model')
 for export_name,export in exports.items():
  allowed={'ProductionLedger','OwnerValidationRPC'} if name=='feast-proxy-production' else set()
  if export_name not in allowed:raise SafeStop('unreviewed export identity')
  if not isinstance(export,dict):raise SafeStop('unreviewed exports metadata')
  expected_type='durable-object' if export_name=='ProductionLedger' else 'worker'
  if export.get('type')!=expected_type or (expected_type=='worker' and 'storage' in export):raise SafeStop('unreviewed export type')
  if export.get('state') is None:export.pop('state',None)
  if export.get('state') not in [None,'created'] or set(export)-{'type','storage','state'}:raise SafeStop('export lifecycle change')
 if name=='feast-proxy-production' and 'ProductionLedger' in exports:
  if runtime['exports']['ProductionLedger'].get('storage')!='sqlite':raise SafeStop('storage drift')
 resources['bindings']=sorted(bindings.values(),key=lambda x:x['name'])
 return resources
def checked_settings(settings):
 if not isinstance(settings,dict):raise SafeStop('unverified settings shape')
 if settings.get('logpush') is not None and settings.get('logpush') is not False:raise SafeStop('unexpected observability')
 observability=settings.get('observability')
 if observability is not None:
  if not isinstance(observability,dict) or observability.get('enabled') is not False:raise SafeStop('unexpected observability')
 return copy.deepcopy(settings)
def snapshot(api,name,expected):
 if active(api,name)!=expected or latest(api,name)!=expected:raise SafeStop('active/latest version mismatch')
 detail=api.request('GET',name,'/versions/'+expected)
 if not isinstance(detail,dict) or detail.get('id')!=expected:raise SafeStop('wrong version metadata')
 settings=checked_settings(api.request('GET',name,'/script-settings'))
 return {'resources':checked_resources(name,detail),'settings':settings}
def same_configuration(a,b):
 x=copy.deepcopy(a);y=copy.deepcopy(b)
 # Code and deployment-origin metadata change; handlers/entrypoints must not change.
 for v in [x,y]:
  v['resources']['script'].pop('etag',None);v['resources']['script'].pop('last_deployed_from',None)
 if x!=y:raise SafeStop('configuration/binding drift')
def metadata(before):
 r=before['resources'];runtime=r['script_runtime']
 result={'main_module':'worker.js','bindings':[{'type':'inherit','name':b['name']} for b in r['bindings']]}
 # Version upload never touches script-level settings. Inherit each binding strictly;
 # copy runtime, but never submit any migration/reset/rename/transfer operation.
 result.update({k:copy.deepcopy(v) for k,v in runtime.items() if k!='migration_tag' and v is not None and not (k=='exports' and not v)})
 return result
def atomic_receipt(path,value):
 # Same-directory replace + file and directory fsync: never truncate last evidence.
 fd,tmp=tempfile.mkstemp(prefix='.'+path.name+'-',dir=path.parent)
 try:
  os.fchmod(fd,0o600)
  with os.fdopen(fd,'w') as stream:
   stream.write(json.dumps(value,indent=2)+'\n');stream.flush();os.fsync(stream.fileno())
  os.replace(tmp,path)
  directory=os.open(path.parent,os.O_RDONLY)
  try:os.fsync(directory)
  finally:os.close(directory)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)
def checked_upload(result,meta):
 if not isinstance(result,dict):raise SafeStop('upload response unverified')
 ident=version_id(result.get('id'))
 if meta.get('exports'):
  reconciliation=result.get('exports_reconciliation')
  keys={'created','deleted','updated','renamed','transfer_pending','transferred','removable_entries','info','warnings'}
  if not isinstance(reconciliation,dict) or set(reconciliation)!=keys:raise SafeStop('export reconciliation unverified')
  if any(not isinstance(v,list) or v for v in reconciliation.values()):raise SafeStop('export reconciliation requires review')
 return ident
def checked_ack(result,new):
 if not isinstance(result,dict):raise SafeStop('deployment acknowledgement unverified')
 version_id(result.get('id'))
 if result.get('strategy')!='percentage' or result.get('versions')!=[{'version_id':new,'percentage':100}]:raise SafeStop('deployment acknowledgement mismatch')
def await_active(api,name,old,new,polls=6,pause=time.sleep):
 # Only after a fully validated acknowledgement. No POST retry, no retry of errors.
 for index in range(polls):
  observed=active(api,name)
  if observed==new:return
  if observed!=old:raise SafeStop('unexpected active version during polling')
  if index+1<polls:pause(1)
 raise SafeStop('acknowledged deployment not yet visible')
def multipart(meta,script):
 boundary='feast-'+uuid.uuid4().hex
 parts=[]
 for name,filename,mime,value in [('metadata',None,'application/json',canonical(meta).encode()),('worker.js','worker.js','application/javascript+module',script)]:
  disposition='form-data; name="'+name+'"'+('' if filename is None else '; filename="'+filename+'"')
  parts.append(('--'+boundary+'\r\nContent-Disposition: '+disposition+'\r\nContent-Type: '+mime+'\r\n\r\n').encode()+value+b'\r\n')
 return b''.join(parts)+('--'+boundary+'--\r\n').encode(),'multipart/form-data; boundary='+boundary

def attempt_path(packet,attempt):
 if not isinstance(attempt,int) or not 1<=attempt<=9:raise SafeStop('invalid explicit attempt')
 return packet/('existing-update-receipt.json' if attempt==1 else 'existing-update-receipt-attempt-'+str(attempt)+'.json')
def check_attempt(packet,attempt):
 path=attempt_path(packet,attempt);previous={}
 if path.exists():raise SafeStop('existing receipt must be inspected')
 for number in range(1,attempt):
  old=attempt_path(packet,number);raw=old.read_bytes();value=json.loads(raw)
  if value.get('state')!='preflight-stopped-no-write' or value.get('stagedVersions')!={} or value.get('deployedVersions')!={} or value.get('providerCalls')!=0 or value.get('ledgerAccessed') is not False or value.get('flagsChanged') is not False or any(e.get('method')!='GET' for e in value.get('requests',[])):raise SafeStop('prior outcome requires inspection')
  previous[old.name]=hashlib.sha256(raw).hexdigest()
 return path,previous

def update(packet,api,attempt=1):
 packet,m,_=reviewed.inspect(packet)
 try:receipt_path,previous=check_attempt(packet,attempt)
 except (ValueError,FileNotFoundError):return False
 receipt={'preservationVerified':None,'requestedChanges':['reviewed code only'],'state':'preflight','stagedVersions':{},'deployedVersions':{},'providerCalls':0,'ledgerAccessed':False,'flagsChanged':False,'attempt':attempt,'previousReceiptSHA256':previous,'requests':[]}
 try:
  with receipt_path.open('x') as f:
   os.fchmod(f.fileno(),0o600);f.write(canonical(receipt)+'\n');f.flush();os.fsync(f.fileno())
 except FileExistsError:return False
 receipt_path.chmod(0o600)
 def save():atomic_receipt(receipt_path,receipt)
 def record_event(event):
  safe={key:event[key] for key in ['method','worker','path','status','cloudflareErrorCodes']}
  if 'resultShape' in event:safe['resultShape']=event['resultShape']
  receipt['requests'].append(safe);save()
 api.on_event=record_event
 wrote=False
 try:
  before={name:snapshot(api,name,expected) for name,expected in EXPECTED.items()}
  receipt['beforeFingerprints']={name:fingerprint(v) for name,v in before.items()};save()
  # Check both before every mutation. Staged uploads must not affect active traffic.
  def guard():
   for name,old in EXPECTED.items():
    expected_latest=receipt['stagedVersions'].get(name,old)
    if active(api,name)!=receipt['deployedVersions'].get(name,old) or latest(api,name)!=expected_latest:raise SafeStop('concurrent version drift')
    if api.request('GET',name,'/script-settings')!=before[name]['settings']:raise SafeStop('concurrent settings drift')
  for folder,name in zip(['production','owner'],EXPECTED):
   reviewed.inspect(packet);guard();script=(packet/folder/'worker.js').read_bytes()
   if hashlib.sha256(script).hexdigest()!=m['files'][folder+'/worker.js']:raise SafeStop('reviewed source changed')
   meta=metadata(before[name]);body,mime=multipart(meta,script)
   receipt['state']='uploading-'+name;save();wrote=True
   result=api.request('POST',name,'/versions?bindings_inherit=strict',body,mime)
   new=checked_upload(result,meta);receipt['stagedVersions'][name]=new;save()
   detail=api.request('GET',name,'/versions/'+new)
   if not isinstance(detail,dict) or detail.get('id')!=new:raise SafeStop('wrong staged version')
   current={'resources':checked_resources(name,detail),'settings':checked_settings(api.request('GET',name,'/script-settings'))}
   same_configuration(before[name],current)
   if active(api,name)!=EXPECTED[name] or latest(api,name)!=new:raise SafeStop('upload changed deployment unexpectedly')
  for name in EXPECTED:
   guard();new=receipt['stagedVersions'][name]
   receipt['state']='deploying-'+name;save();wrote=True
   ack=api.request('POST',name,'/deployments',canonical({'strategy':'percentage','versions':[{'version_id':new,'percentage':100}]}).encode(),'application/json')
   checked_ack(ack,new)
   receipt.setdefault('acknowledgedDeployments',{})[name]=new;save()
   await_active(api,name,EXPECTED[name],new)
   current=snapshot(api,name,new);same_configuration(before[name],current)
   receipt['deployedVersions'][name]=new;save()
  for name in EXPECTED:same_configuration(before[name],snapshot(api,name,receipt['deployedVersions'][name]))
  receipt['preservationVerified']=True
  receipt['state']='updated-off-needs-public-health-verification';save();return True
 except BaseException as error:
  receipt['stoppedAt']=receipt['state'];receipt['failureType']=type(error).__name__
  receipt['failureFrames']=[{'module':pathlib.Path(f.filename).name,'line':f.lineno,'function':f.name} for f in traceback.extract_tb(error.__traceback__)]
  if isinstance(error,SafeStop):receipt['validationCode']=error.args[0]
  if isinstance(getattr(error,'code',None),int):receipt['httpStatus']=error.code
  receipt['state']='uncertain-stop-inspect-no-retry' if wrote else 'preflight-stopped-no-write'
  try:save()
  except OSError:pass # Last durable intent remains authoritative; never repeat a mutation.
  return False

def main():
 p=argparse.ArgumentParser();p.add_argument('packet');p.add_argument('--update-existing',action='store_true');p.add_argument('--attempt',type=int,default=1,choices=range(1,10));a=p.parse_args()
 try:
  packet,_,_=reviewed.inspect(a.packet);check_attempt(packet,a.attempt)
 except Exception:print('STOP: reviewed packet validation failed. No network request.');return 1
 if not a.update_existing:print('Reviewed existing-Worker packet verified offline. No authentication or deployment.');return 0
 if not sys.stdin.isatty():print('STOP: hidden token entry requires interactive Terminal.');return 1
 resource.setrlimit(resource.RLIMIT_CORE,(0,0));token='';api=None
 try:
  warnings.simplefilter('error',getpass.GetPassWarning)
  token=getpass.getpass('Approved two-hour Cloudflare update token (hidden): ')
  if not re.fullmatch('[A-Za-z0-9_-]{20,200}',token):print('STOP: invalid token format.');return 1
  api=API(token);ok=update(packet,api,a.attempt)
  print('Existing Workers updated OFF; public health verification still required.' if ok else 'STOP: inspect safe receipt and versions. No automatic retry.')
  return 0 if ok else 1
 except BaseException:print('STOP: no automatic retry. Inspect receipt before proceeding.');return 1
 finally:
  if api is not None:api.token=''
  token=''
if __name__=='__main__':sys.exit(main())
