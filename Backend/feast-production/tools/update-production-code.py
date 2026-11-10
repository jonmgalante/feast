#!/usr/bin/env python3
"""One production code upload/activation, preserving an exact live ON configuration.
Default is offline. No settings, secret, namespace, owner or ledger writes.
Reuses audited HTTP/serialization utilities, NEVER the old two-Worker/OFF update flow.
"""
import argparse,copy,getpass,importlib.util,json,os,pathlib,re,resource,sys,time,warnings
spec=importlib.util.spec_from_file_location('utilities',pathlib.Path(__file__).with_name('update-existing.py'))
u=importlib.util.module_from_spec(spec);spec.loader.exec_module(u)
PRODUCTION='feast-proxy-production';OWNER='feast-owner-validation'
# Existing additive namespace, verified from retained 2026-11-10 release metadata.
# Code-only updates inherit it; this helper never creates or migrates storage.
ANSWER_JOBS_NAMESPACE='36011118f6cc49ee910df65aa1a4cd8b'
MODULE_SHA='2279aa24d13cb9982b7dc08602caf2720cde03993355903eef9627695b9a3147'
OWNER_MODULE_SHA='26708c9e883c2c9fdf4fe9922f096bf0ddc0ebdb33486e5b7a8985279613ade9'
class ProductionAPI(u.API):
 def request(self,method,name,suffix='',body=None,content_type=None):
  if method!='GET' and name!=PRODUCTION:raise u.SafeStop('owner writes forbidden')
  return super().request(method,name,suffix,body,content_type)
class OwnerCodeAPI(u.API):
 def request(self,method,name,suffix='',body=None,content_type=None):
  if method!='GET' and name!=OWNER:raise u.SafeStop('production writes forbidden in owner-only action')
  return super().request(method,name,suffix,body,content_type)
def resources(name,detail):
 if not isinstance(detail,dict) or not isinstance(detail.get('resources'),dict):raise u.SafeStop('resource shape')
 r=copy.deepcopy(detail['resources'])
 if set(r)!={'bindings','script','script_runtime'} or not isinstance(r['script'],dict):raise u.SafeStop('resource shape')
 b=u.binding_view(r['bindings']);v={k:x.get('text') for k,x in b.items() if x['type']=='plain_text'}
 required={'NATIVE_RESEARCH_ENABLED':'true','LIVE_AI':'true','ALLOW_PUBLIC_LOOKUP':'true','ALLOW_RECONCILED_BUDGET':'true','ENABLED':'false' if name==PRODUCTION else 'true'}
 if name==PRODUCTION:required.update({'ENVIRONMENT':'production','OWNER_VALIDATION_ENABLED':'true','ALLOW_LEGACY_RECONCILIATION':'true'})
 if any(v.get(k)!=value for k,value in required.items()):raise u.SafeStop('runtime flag drift')
 if v.get('RESEARCH_PILOT_ENABLED') not in [None,'false']:raise u.SafeStop('pilot must remain disabled')
 if name==PRODUCTION:
  binding=b.get('PRODUCTION_STATE',{})
  if binding.get('type')!='durable_object_namespace' or binding.get('namespace_id')!=u.NAMESPACE or binding.get('class_name') not in [None,'ProductionLedger']:raise u.SafeStop('namespace drift')
  if b.get('OPENAI_API_KEY',{}).get('type')!='secret_text':raise u.SafeStop('provider secret absent')
 else:
  binding=b.get('PRODUCTION',{})
  if binding.get('type')!='service' or binding.get('service')!=PRODUCTION or binding.get('entrypoint')!='OwnerValidationRPC':raise u.SafeStop('RPC drift')
  if b.get('OWNER_TOKEN_HASHES_JSON',{}).get('type')!='secret_text':raise u.SafeStop('owner secret absent')
 runtime=r['script_runtime']
 if not isinstance(runtime,dict) or set(runtime)-u.RUNTIME_KEYS or runtime.get('compatibility_date')!='2026-10-20':raise u.SafeStop('unknown runtime')
 recovery_schema=any([name==PRODUCTION and 'ASK_FEAST_RECOVERY_ENABLED' in b,'ANSWER_JOBS' in b,runtime.get('migration_tag')=='answer-jobs-v1',isinstance(runtime.get('exports'),dict) and 'AnswerJobs' in runtime['exports']])
 if recovery_schema:
  jobs=b.get('ANSWER_JOBS',{})
  if name!=PRODUCTION or v.get('ASK_FEAST_RECOVERY_ENABLED')!='false':raise u.SafeStop('recovery must remain disabled')
  if jobs.get('type')!='durable_object_namespace' or jobs.get('namespace_id')!=ANSWER_JOBS_NAMESPACE or jobs.get('class_name')!='AnswerJobs':raise u.SafeStop('answer jobs namespace drift')
  if runtime.get('migration_tag')!='answer-jobs-v1':raise u.SafeStop('migration drift')
  # Cloudflare may omit optional exports metadata entirely. If supplied, its
  # declaration must include AnswerJobs; the reviewed code hash still pins code.
  if runtime.get('exports') is not None and (not isinstance(runtime['exports'],dict) or 'AnswerJobs' not in runtime['exports']):raise u.SafeStop('answer jobs export absent')
 elif runtime.get('migration_tag') not in [None,'production-v1']:raise u.SafeStop('migration drift')
 for key in ['limits','migration_tag','usage_model']:
  if runtime.get(key) is None:runtime.pop(key,None)
 if runtime.get('usage_model') not in [None,'standard','bundled','unbound']:raise u.SafeStop('usage mode')
 if runtime.get('compatibility_flags') is None:runtime['compatibility_flags']=[]
 if not isinstance(runtime['compatibility_flags'],list) or any(not isinstance(x,str) for x in runtime['compatibility_flags']):raise u.SafeStop('runtime flags')
 if runtime.get('exports') is None:runtime['exports']={}
 exports=runtime['exports'];allowed=({'ProductionLedger','OwnerValidationRPC'}|({'AnswerJobs'} if recovery_schema else set())) if name==PRODUCTION else set()
 if not isinstance(exports,dict) or set(exports)-allowed:raise u.SafeStop('exports shape')
 for key,value in exports.items():
  kind='durable-object' if key in ['ProductionLedger','AnswerJobs'] else 'worker'
  if not isinstance(value,dict) or set(value)-{'type','state','storage'} or value.get('type')!=kind or value.get('state') not in [None,'created']:raise u.SafeStop('export lifecycle')
  if (kind=='durable-object' and value.get('storage')!='sqlite') or (kind=='worker' and 'storage' in value):raise u.SafeStop('export storage')
  if value.get('state') is None:value.pop('state',None)
 limits=runtime.get('limits')
 if limits is not None and (not isinstance(limits,dict) or set(limits)-{'cpu_ms'} or any(not isinstance(x,int) or isinstance(x,bool) or x<=0 for x in limits.values())):raise u.SafeStop('limits shape')
 r['bindings']=sorted(b.values(),key=lambda x:x['name']);return r
def snapshot(api,name,ident,newest=None):
 if u.active(api,name)!=ident or u.latest(api,name)!=(newest or ident):raise u.SafeStop('version drift')
 detail=api.request('GET',name,'/versions/'+ident)
 if not isinstance(detail,dict) or detail.get('id')!=ident:raise u.SafeStop('detail identity')
 return {'resources':resources(name,detail),'settings':u.checked_settings(api.request('GET',name,'/script-settings'))}
def wait_version(read,old,new,pause=time.sleep):
 for n in range(6):
  value=read()
  if value==new:return
  if value!=old:raise u.SafeStop('unexpected version during visibility check')
  if n<5:pause(1)
 raise u.SafeStop('version visibility unresolved')
def inspect(packet,expected_hash=MODULE_SHA,target=PRODUCTION):
 packet,m,_=u.reviewed.inspect(packet)
 if target not in [PRODUCTION,OWNER]:raise u.SafeStop('invalid code target')
 if m['files'][('production' if target==PRODUCTION else 'owner')+'/worker.js']!=expected_hash:raise u.SafeStop('unreviewed module')
 return packet,m
def run(packet,api,expected,receipt_path,expected_hash=MODULE_SHA,pause=time.sleep,target=PRODUCTION):
 packet,m=inspect(packet,expected_hash,target);companion=OWNER if target==PRODUCTION else PRODUCTION;expected={n:u.version_id(expected[n]) for n in [PRODUCTION,OWNER]}
 receipt_path=pathlib.Path(receipt_path)
 receipt={'state':'preflight','expectedVersions':expected,'requests':[],'stagedVersion':None,'verifiedVersions':{},'preservationVerified':None,'moduleSHA256':expected_hash,'providerCalls':0,'ledgerAccessed':False,'requestedChanges':[('production' if target==PRODUCTION else 'owner')+' code only'],'ownerWrites':0}
 try:
  with receipt_path.open('x') as stream:
   os.fchmod(stream.fileno(),0o600);stream.write(u.canonical(receipt)+'\n');stream.flush();os.fsync(stream.fileno())
 except FileExistsError:return False
 def save():u.atomic_receipt(receipt_path,receipt)
 def event(e):
  receipt['requests'].append({k:e[k] for k in ['method','worker','path','status','cloudflareErrorCodes']});receipt['ownerWrites']+=int(e['method']!='GET' and e['worker']==OWNER);save()
 api.on_event=event;wrote=False
 try:
  before={n:snapshot(api,n,expected[n]) for n in expected};receipt['beforeFingerprints']={n:u.fingerprint(v) for n,v in before.items()};save()
  def guard():
   for n in expected:u.same_configuration(before[n],snapshot(api,n,expected[n],receipt['stagedVersion'] if n==target else None))
  guard();inspect(packet,expected_hash,target);script=(packet/('production' if target==PRODUCTION else 'owner')/'worker.js').read_bytes()
  if u.hashlib.sha256(script).hexdigest()!=expected_hash:raise u.SafeStop('reviewed module changed')
  body,mime=u.multipart(u.metadata(before[target]),script)
  receipt['state']='upload-intent';save();wrote=True
  result=api.request('POST',target,'/versions?bindings_inherit=strict',body,mime)
  new=u.checked_upload(result,u.metadata(before[target]));receipt['stagedVersion']=new;save()
  wait_version(lambda:u.latest(api,target),expected[target],new,pause)
  detail=api.request('GET',target,'/versions/'+new)
  if not isinstance(detail,dict) or detail.get('id')!=new:raise u.SafeStop('staged identity')
  staged={'resources':resources(target,detail),'settings':u.checked_settings(api.request('GET',target,'/script-settings'))};u.same_configuration(before[target],staged)
  guard();receipt['state']='activation-intent';save()
  ack=api.request('POST',target,'/deployments',u.canonical({'strategy':'percentage','versions':[{'version_id':new,'percentage':100}]}).encode(),'application/json')
  # A successful API envelope is not activation proof. Record only structural metadata;
  # even an unfamiliar acknowledgement is reconciled by GETs, never another POST.
  receipt['acknowledgementShape']={'type':type(ack).__name__,'keyCount':len(ack) if isinstance(ack,dict) else 0};save()
  wait_version(lambda:u.active(api,target),expected[target],new,pause)
  u.same_configuration(before[target],snapshot(api,target,new))
  u.same_configuration(before[companion],snapshot(api,companion,expected[companion]))
  # Last pair check catches production drift while checking owner.
  if u.active(api,target)!=new or u.latest(api,target)!=new:raise u.SafeStop('final production drift')
  if api.request('GET',target,'/script-settings')!=before[target]['settings']:raise u.SafeStop('final settings drift')
  receipt.update(state='verified-production-only-update' if target==PRODUCTION else 'verified-owner-only-update',preservationVerified=True,verifiedVersions={**expected,target:new});save();return True
 except BaseException as error:
  receipt.update(state='uncertain-stop-reconcile-before-retry' if wrote else 'preflight-stopped-no-write',failureType=type(error).__name__)
  if isinstance(error,u.SafeStop):receipt['validationCode']=error.args[0]
  try:save()
  except OSError:pass
  return False

def inspect_current(api,receipt_path):
 receipt_path=pathlib.Path(receipt_path)
 receipt={'state':'read-only-preflight','versions':{},'requests':[],'externalWrites':0}
 try:
  with receipt_path.open('x') as stream:
   os.fchmod(stream.fileno(),0o600);stream.write(u.canonical(receipt)+'\n');stream.flush();os.fsync(stream.fileno())
 except FileExistsError:return False
 def save():u.atomic_receipt(receipt_path,receipt)
 def event(e):receipt['requests'].append({k:e[k] for k in ['method','worker','path','status','cloudflareErrorCodes']});save()
 api.on_event=event
 try:
  current={n:u.active(api,n) for n in [PRODUCTION,OWNER]};receipt['versions']=current;save()
  # Inspection never authorizes writes. Return current full IDs for explicit review;
  # run() separately requires exact caller-approved versions before any mutation.
  views={n:snapshot(api,n,current[n]) for n in current}
  receipt.update(state='verified-read-only-preflight',configurationFingerprints={n:u.fingerprint(v) for n,v in views.items()},runtimeGates='validated ON; public enrollment unchanged',namespace=u.NAMESPACE)
  save();print(json.dumps({'state':receipt['state'],'versions':current}));return True
 except BaseException as error:
  receipt.update(state='read-only-preflight-stopped',failureType=type(error).__name__)
  if isinstance(error,u.SafeStop):receipt['validationCode']=error.args[0]
  try:save()
  except OSError:pass
  return False
class ReadOnlyAPI(ProductionAPI):
 def request(self,method,*args,**kwargs):
  if method!='GET':raise u.SafeStop('read-only action')
  return super().request(method,*args,**kwargs)

def main():
 p=argparse.ArgumentParser();p.add_argument('packet');p.add_argument('--expected-production');p.add_argument('--expected-owner');p.add_argument('--receipt',required=True);action=p.add_mutually_exclusive_group();action.add_argument('--update-production',action='store_true');action.add_argument('--update-owner',action='store_true');action.add_argument('--inspect-current',action='store_true');p.add_argument('--token-stdin',action='store_true');a=p.parse_args()
 try:
  inspect(a.packet,OWNER_MODULE_SHA if a.update_owner else MODULE_SHA,OWNER if a.update_owner else PRODUCTION)
  if not a.inspect_current:u.version_id(a.expected_production);u.version_id(a.expected_owner)
 except Exception:print('STOP: offline review inputs invalid.');return 1
 if not a.update_production and not a.update_owner and not a.inspect_current:print('Production-only inputs verified offline. No credential or network access.');return 0
 if pathlib.Path(a.receipt).exists():print('STOP: existing receipt requires reconciliation; no credential read.');return 1
 resource.setrlimit(resource.RLIMIT_CORE,(0,0));token='';api=None
 try:
  if a.token_stdin:
   if sys.stdin.isatty():raise u.SafeStop('credential pipe required')
   token=sys.stdin.buffer.read(202).decode().strip()
  else:
   if not sys.stdin.isatty():raise u.SafeStop('hidden input requires Terminal')
   warnings.simplefilter('error',getpass.GetPassWarning);token=getpass.getpass('Approved Feast deployment token (hidden): ')
  if not re.fullmatch('[A-Za-z0-9_-]{20,200}',token):raise u.SafeStop('token format')
  api=(ReadOnlyAPI if a.inspect_current else OwnerCodeAPI if a.update_owner else ProductionAPI)(token)
  ok=inspect_current(api,a.receipt) if a.inspect_current else run(a.packet,api,{PRODUCTION:a.expected_production,OWNER:a.expected_owner},a.receipt,expected_hash=OWNER_MODULE_SHA if a.update_owner else MODULE_SHA,target=OWNER if a.update_owner else PRODUCTION)
  print(('Read-only preflight verified.' if a.inspect_current else 'Production-only update verified.') if ok else 'STOP: inspect redacted receipt; no automatic retry.');return 0 if ok else 1
 except BaseException:print('STOP: no automatic retry; inspect receipt and remote state.');return 1
 finally:
  if api is not None:api.token=''
  token=''
if __name__=='__main__':sys.exit(main())
