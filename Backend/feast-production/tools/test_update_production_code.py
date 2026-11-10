import copy,importlib.util,json,pathlib,tempfile,unittest
from unittest.mock import patch
path=pathlib.Path(__file__).parent
spec=importlib.util.spec_from_file_location('production_update',path/'update-production-code.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
spec=importlib.util.spec_from_file_location('fixtures',path/'test_update_existing.py');f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
class LiveAPI(f.MockAPI):
 def __init__(self):
  super().__init__()
  for name in self.live:
   r=self.versions[name][self.live[name]]['resources'];v={b['name']:b for b in r['bindings'] if b['type']=='plain_text'}
   for key in ['NATIVE_RESEARCH_ENABLED','LIVE_AI','ALLOW_PUBLIC_LOOKUP','ALLOW_RECONCILED_BUDGET']:
    if key in v:v[key]['text']='true'
    else:r['bindings'].append({'name':key,'type':'plain_text','text':'true'})
   if name==h.PRODUCTION:r['bindings'].append({'name':'ALLOW_LEGACY_RECONCILIATION','type':'plain_text','text':'true'})
  self.ack={'id':f.uid(200)} # actual activation reads, not strict ack shape, are proof
 def request(self,method,name,suffix='',body=None,content_type=None):
  if method=='POST' and name!=h.PRODUCTION:raise AssertionError('owner mutation')
  result=super().request(method,name,suffix,body,content_type)
  if method=='POST' and suffix=='/deployments':return copy.deepcopy(self.ack)
  return result
def add_recovery_off_schema(api):
 r=api.versions[h.PRODUCTION][api.live[h.PRODUCTION]]['resources']
 r['bindings'] += [{'name':'ASK_FEAST_RECOVERY_ENABLED','type':'plain_text','text':'false'}, {'name':'ANSWER_JOBS','type':'durable_object_namespace','namespace_id':'36011118f6cc49ee910df65aa1a4cd8b','class_name':'AnswerJobs'}]
 r['script_runtime']['migration_tag']='answer-jobs-v1'
 r['script_runtime']['exports']['AnswerJobs']={'type':'durable-object','storage':'sqlite','state':'created'}
 return r
class OwnerLiveAPI(LiveAPI):
 def request(self,method,name,suffix='',body=None,content_type=None):
  if method!='GET' and name!=h.OWNER:raise AssertionError('production mutation in owner action')
  result=f.MockAPI.request(self,method,name,suffix,body,content_type)
  if getattr(self,'on_event',None):self.on_event({'method':method,'worker':name,'path':suffix,'status':200,'cloudflareErrorCodes':[]})
  return copy.deepcopy(self.ack) if method=='POST' and suffix=='/deployments' else result
class Tests(unittest.TestCase):
 setUp=f.Tests.setUp
 tearDown=f.Tests.tearDown
 def run_update(self,api):return h.run(self.packet,api,dict(h.u.EXPECTED),self.packet/'production-only-receipt.json',h.u.reviewed.sha(self.packet/'production/worker.js'),pause=lambda _:None)
 def receipt(self):return json.loads((self.packet/'production-only-receipt.json').read_text())
 def test_recovery_off_current_schema_preserved_by_code_only_update(self):
  api=LiveAPI();add_recovery_off_schema(api);before=copy.deepcopy(api.versions[h.PRODUCTION][api.live[h.PRODUCTION]]['resources'])
  h.resources(h.PRODUCTION,api.versions[h.PRODUCTION][api.live[h.PRODUCTION]])
  self.assertTrue(self.run_update(api));self.assertEqual(len(api.events),2)
  after=api.versions[h.PRODUCTION][api.live[h.PRODUCTION]]['resources']
  self.assertEqual(sorted(before['bindings'],key=lambda x:x['name']),sorted(after['bindings'],key=lambda x:x['name']))
  self.assertEqual(before['script_runtime'],after['script_runtime'])
  metadata=api.uploads[0][1];self.assertNotIn('migration_tag',metadata);self.assertNotIn('migrations',metadata)
  self.assertTrue(all(x['type']=='inherit' for x in metadata['bindings']))
 def test_retained_current_metadata_may_omit_optional_exports_without_inventing_them(self):
  api=LiveAPI();r=add_recovery_off_schema(api);del r['script_runtime']['exports']
  self.assertTrue(self.run_update(api));self.assertEqual(len(api.events),2)
  metadata=api.uploads[0][1]
  self.assertNotIn('exports',metadata);self.assertNotIn('migration_tag',metadata);self.assertNotIn('migrations',metadata)
 def test_recovery_shape_rejects_activation_namespace_export_or_migration_drift(self):
  for bad in ['enabled','missing-flag','missing-binding','namespace','class','migration','missing-export','extra-export','storage']:
   with self.subTest(bad=bad):
    api=LiveAPI();r=add_recovery_off_schema(api);b={x['name']:x for x in r['bindings']};runtime=r['script_runtime']
    if bad=='enabled':b['ASK_FEAST_RECOVERY_ENABLED']['text']='true'
    if bad=='missing-flag':r['bindings'].remove(b['ASK_FEAST_RECOVERY_ENABLED'])
    if bad=='missing-binding':r['bindings'].remove(b['ANSWER_JOBS'])
    if bad=='namespace':b['ANSWER_JOBS']['namespace_id']='unreviewed'
    if bad=='class':b['ANSWER_JOBS']['class_name']='Replacement'
    if bad=='migration':runtime['migration_tag']='unreviewed'
    if bad=='missing-export':del runtime['exports']['AnswerJobs']
    if bad=='extra-export':runtime['exports']['Extra']={'type':'durable-object','storage':'sqlite'}
    if bad=='storage':runtime['exports']['AnswerJobs']['storage']='kv'
    with self.assertRaises(h.u.SafeStop):h.resources(h.PRODUCTION,api.versions[h.PRODUCTION][api.live[h.PRODUCTION]])
 def test_owner_only_upload_preserves_production_secrets_namespace_and_live_settings(self):
  api=OwnerLiveAPI();before=copy.deepcopy(api.versions[h.PRODUCTION]);settings=copy.deepcopy(api.settings)
  self.assertTrue(h.run(self.packet,api,dict(h.u.EXPECTED),self.packet/'owner-only-receipt.json',h.u.reviewed.sha(self.packet/'owner/worker.js'),pause=lambda _:None,target=h.OWNER))
  self.assertEqual(api.events,[(h.OWNER,'/versions?bindings_inherit=strict'),(h.OWNER,'/deployments')]);self.assertEqual(before,api.versions[h.PRODUCTION]);self.assertEqual(settings,api.settings)
  receipt=json.loads((self.packet/'owner-only-receipt.json').read_text());self.assertEqual(receipt['state'],'verified-owner-only-update');self.assertEqual(receipt['ownerWrites'],2)
 def test_native_must_stay_on_and_pilot_off_before_upload(self):
  for name in [h.PRODUCTION,h.OWNER]:
   api=LiveAPI();detail=api.versions[name][api.live[name]];h.resources(name,detail)
   native=next(b for b in detail['resources']['bindings'] if b['name']=='NATIVE_RESEARCH_ENABLED')
   for bad in ['false','TRUE','']:
    native['text']=bad
    with self.assertRaises(h.u.SafeStop):h.resources(name,detail)
   native['text']='true';detail['resources']['bindings'].append({'name':'RESEARCH_PILOT_ENABLED','type':'plain_text','text':'true'})
   with self.assertRaises(h.u.SafeStop):h.resources(name,detail)
   detail['resources']['bindings'][-1]['text']='false';h.resources(name,detail)
 def test_target_specific_api_guards_never_expand_to_other_worker(self):
  with self.assertRaises(h.u.SafeStop):h.OwnerCodeAPI('OFFLINE').request('POST',h.PRODUCTION,'/versions')
  with self.assertRaises(h.u.SafeStop):h.ProductionAPI('OFFLINE').request('POST',h.OWNER,'/versions')
 def test_owner_upload_lost_ack_never_repeats_and_preserves_original_deployment(self):
  api=OwnerLiveAPI();api.fail_write=True
  self.assertFalse(h.run(self.packet,api,dict(h.u.EXPECTED),self.packet/'owner-only-receipt.json',h.u.reviewed.sha(self.packet/'owner/worker.js'),pause=lambda _:None,target=h.OWNER))
  self.assertEqual(len(api.events),1);self.assertEqual(api.live,h.u.EXPECTED)
  receipt=json.loads((self.packet/'owner-only-receipt.json').read_text());self.assertEqual(receipt['state'],'uncertain-stop-reconcile-before-retry')
 def test_success_applies_metadata_and_preserves_live_owner_and_all_configuration(self):
  api=LiveAPI();owner=copy.deepcopy(api.versions[h.OWNER]);settings=copy.deepcopy(api.settings);self.assertTrue(self.run_update(api));self.assertEqual(api.events,[(h.PRODUCTION,'/versions?bindings_inherit=strict'),(h.PRODUCTION,'/deployments')]);self.assertEqual(owner,api.versions[h.OWNER]);self.assertEqual(settings,api.settings);self.assertTrue(self.receipt()['preservationVerified'])
  self.assertFalse(self.run_update(api));self.assertEqual(len(api.events),2)
 def test_preflight_mismatch_unknown_flags_or_namespace_stops_without_write(self):
  for kind in ['version','flag','namespace']:
   api=LiveAPI()
   if kind=='version':api.live[h.OWNER]=f.uid(999)
   else:
    bindings=api.versions[h.PRODUCTION][api.live[h.PRODUCTION]]['resources']['bindings']
    for b in bindings:
     if kind=='flag' and b['name']=='LIVE_AI':b['text']='false'
     if kind=='namespace' and b['name']=='PRODUCTION_STATE':b['namespace_id']='wrong'
   target=self.packet/'production-only-receipt.json'
   if target.exists():target.unlink() # isolated fresh fixture, never a live retry
   self.assertFalse(self.run_update(api));self.assertEqual(api.events,[])
 def test_staged_metadata_or_concurrent_owner_drift_prevents_activation(self):
  api=LiveAPI();api.alter_stage=True;self.assertFalse(self.run_update(api));self.assertEqual(len(api.events),1);self.assertEqual(api.live,h.u.EXPECTED)
 def test_timeout_never_retries_or_claims_no_write(self):
  api=LiveAPI();api.fail_write=True;self.assertFalse(self.run_update(api));self.assertEqual(len(api.events),1);self.assertEqual(self.receipt()['state'],'uncertain-stop-reconcile-before-retry');self.assertFalse(self.run_update(api));self.assertEqual(len(api.events),1)
 def test_delayed_activation_is_get_only_and_tolerates_minimal_ack(self):
  class Delayed(LiveAPI):
   pending=None;reads=0
   def request(self,method,name,suffix='',body=None,content_type=None):
    if method=='POST' and suffix=='/deployments':
     result=super().request(method,name,suffix,body,content_type);self.pending=self.live[name];self.live[name]=h.u.EXPECTED[name];return result
    if name==h.PRODUCTION and suffix=='/deployments' and self.pending:
     self.reads+=1
     if self.reads==3:self.live[name]=self.pending
    return super().request(method,name,suffix,body,content_type)
  api=Delayed();self.assertTrue(self.run_update(api));self.assertEqual(len(api.events),2);self.assertEqual(api.reads,5) # poll3 + snapshot + final
 def test_postwrite_read_failure_stops_without_second_mutation(self):
  class FailedRead(LiveAPI):
   def request(self,method,name,suffix='',body=None,content_type=None):
    if method=='GET' and len(self.events)==1 and suffix=='/versions':raise TimeoutError('private diagnostic not logged')
    return super().request(method,name,suffix,body,content_type)
  api=FailedRead();self.assertFalse(self.run_update(api));self.assertEqual(len(api.events),1);self.assertEqual(self.receipt()['state'],'uncertain-stop-reconcile-before-retry')
 def test_final_owner_drift_is_not_reported_success(self):
  class Drift(LiveAPI):
   def request(self,method,name,suffix='',body=None,content_type=None):
    result=super().request(method,name,suffix,body,content_type)
    if method=='POST' and suffix=='/deployments':self.live[h.OWNER]=f.uid(999)
    return result
  api=Drift();self.assertFalse(self.run_update(api));self.assertIsNone(self.receipt()['preservationVerified']);self.assertEqual(len(api.events),2)
 def test_production_api_forbids_owner_post_before_transport(self):
  api=h.ProductionAPI('OFFLINE_VALUE')
  with self.assertRaises(h.u.SafeStop):api.request('POST',h.OWNER,'/deployments')
 def test_unknown_runtime_nullable_known_fields_and_no_settings_write(self):
  api=LiveAPI();r=api.versions[h.PRODUCTION][api.live[h.PRODUCTION]]['resources'];r['script_runtime'].update(exports=None,compatibility_flags=None,limits=None);api.settings[h.PRODUCTION]['observability']=None
  self.assertTrue(self.run_update(api));self.assertTrue(all(suffix in ['/versions?bindings_inherit=strict','/deployments'] for _,suffix in api.events))
 def test_activation_timeout_or_foreign_version_never_repeats_post(self):
  class NoActivation(LiveAPI):
   def request(self,method,name,suffix='',body=None,content_type=None):
    result=super().request(method,name,suffix,body,content_type)
    if method=='POST' and suffix=='/deployments':self.live[name]=h.u.EXPECTED[name]
    return result
  api=NoActivation();self.assertFalse(self.run_update(api));self.assertEqual(len(api.events),2);self.assertEqual(self.receipt()['state'],'uncertain-stop-reconcile-before-retry')
 def test_read_only_inspection_returns_full_ids_and_preserves_all_state(self):
  api=LiveAPI();full={h.PRODUCTION:'756be730-1111-4111-8111-111111111111',h.OWNER:'45e8a5c6-2222-4222-8222-222222222222'}
  for n,ident in full.items():
   detail=copy.deepcopy(api.versions[n][api.live[n]]);detail['id']=ident;api.versions[n]={ident:detail};api.live[n]=ident;api.newest[n]=ident
  before=copy.deepcopy((api.live,api.newest,api.versions,api.settings));path=self.packet/'preflight.json'
  self.assertTrue(h.inspect_current(api,path));self.assertEqual(json.loads(path.read_text())['versions'],full);self.assertEqual(before,(api.live,api.newest,api.versions,api.settings));self.assertEqual(api.events,[])
 def test_read_only_action_rejects_write_and_reports_current_versions_without_mutation(self):
  with self.assertRaises(h.u.SafeStop):h.ReadOnlyAPI('OFFLINE').request('POST',h.PRODUCTION,'/deployments')
  api=LiveAPI();self.assertTrue(h.inspect_current(api,self.packet/'preflight.json'));self.assertEqual(api.events,[]);self.assertEqual(json.loads((self.packet/'preflight.json').read_text())['versions'],api.live)
if __name__=='__main__':unittest.main()
