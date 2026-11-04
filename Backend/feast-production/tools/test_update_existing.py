import copy,importlib.util,json,pathlib,tempfile,unittest,io,urllib.error,shutil
from email.parser import BytesParser
from email.policy import default
spec=importlib.util.spec_from_file_location('update',pathlib.Path(__file__).with_name('update-existing.py'));h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
def empty_reconciliation():return {k:[] for k in ['created','deleted','updated','renamed','transfer_pending','transferred','removable_entries','info','warnings']}
def uid(n):return '00000000-0000-4000-8000-'+str(n).zfill(12)
def details(name,ident):
 production=name=='feast-proxy-production'
 variables={'LIVE_AI':'false','ENABLED':'false' if production else 'true','PRESERVE_EXTRA':'unchanged'}
 if production:variables.update({'ENVIRONMENT':'production','OWNER_VALIDATION_ENABLED':'true'})
 bindings=[{'name':k,'type':'plain_text','text':v} for k,v in variables.items()]
 bindings.append({'name':'OPENAI_API_KEY' if production else 'OWNER_TOKEN_HASHES_JSON','type':'secret_text'})
 bindings.append({'name':'PRODUCTION_STATE','type':'durable_object_namespace','namespace_id':h.NAMESPACE,'class_name':'ProductionLedger'} if production else {'name':'PRODUCTION','type':'service','service':'feast-proxy-production','entrypoint':'OwnerValidationRPC'})
 runtime={'compatibility_date':'2026-10-20','compatibility_flags':[],'usage_model':'standard','limits':{'cpu_ms':10}}
 if production:runtime.update({'migration_tag':'production-v1','exports':{'ProductionLedger':{'type':'durable-object','storage':'sqlite','state':'created'},'OwnerValidationRPC':{'type':'worker','state':'created'}}})
 return {'id':ident,'resources':{'bindings':bindings,'script':{'etag':'old-hash','handlers':['fetch'],'named_handlers':[{'name':'OwnerValidationRPC','handlers':['fetch']}] if production else [],'last_deployed_from':'dash'},'script_runtime':runtime}}
class MockAPI:
 def __init__(self):
  self.live=dict(h.EXPECTED);self.newest=dict(self.live);self.versions={n:{v:details(n,v)} for n,v in self.live.items()};self.settings={n:{'logpush':False,'observability':{'enabled':False},'tags':['preserved']} for n in self.live};self.events=[];self.uploads=[];self.fail_write=False;self.alter_stage=False;self.drift=False
 def request(self,method,name,suffix='',body=None,content_type=None):
  if method=='GET':
   if self.drift and self.events and suffix=='/deployments':self.live[name]=uid(999)
   if suffix=='/deployments':return {'deployments':[{'versions':[{'version_id':self.live[name],'percentage':100}]}]}
   if suffix=='/versions':return {'items':[{'id':self.newest[name],'number':2}]}
   if suffix=='/script-settings':return copy.deepcopy(self.settings[name])
   if suffix.startswith('/versions/'):return copy.deepcopy(self.versions[name][suffix.split('/')[-1]])
   raise AssertionError('Unexpected read '+suffix)
  self.events.append((name,suffix))
  if self.fail_write:raise TimeoutError('Do not persist this body or fake-token-sentinel')
  if suffix.startswith('/versions?'):
   assert suffix=='/versions?bindings_inherit=strict'
   message=BytesParser(policy=default).parsebytes(('Content-Type: '+content_type+'\r\nMIME-Version: 1.0\r\n\r\n').encode()+body)
   parts={x.get_param('name',header='content-disposition'):x.get_payload(decode=True) for x in message.iter_parts()}
   meta=json.loads(parts['metadata']);self.uploads.append((name,meta,parts['worker.js']))
   new=uid(len(self.uploads));view=copy.deepcopy(self.versions[name][self.newest[name]]);view['id']=new;view['resources']['script'].update({'etag':'new-hash','last_deployed_from':'api'})
   # Apply actual submitted request contract, not assumed preservation.
   old={b['name']:b for b in view['resources']['bindings']}
   view['resources']['bindings']=[copy.deepcopy(old[b['name']]) if b['type']=='inherit' else copy.deepcopy(b) for b in meta['bindings']]
   runtime=view['resources']['script_runtime']
   for key in h.RUNTIME_KEYS-{'migration_tag'}:
    if key in meta:runtime[key]=copy.deepcopy(meta[key])
    else:runtime.pop(key,None)
   if self.alter_stage and name=='feast-proxy-production':view['resources']['bindings'][-1]['namespace_id']='wrong'
   self.versions[name][new]=view;self.newest[name]=new;return {'id':new,'exports_reconciliation':empty_reconciliation()}
  if suffix=='/deployments':
   value=json.loads(body);assert value['strategy']=='percentage';assert value['versions'][0]['percentage']==100;self.live[name]=value['versions'][0]['version_id'];return {'id':uid(200),'strategy':'percentage','versions':value['versions']}
  raise AssertionError('Unexpected write')
def wire_api(fixture,direct_lists=False):
 api=h.API('cfat_offline_fixture_not_a_real_token')
 class Opener:
  def open(inner,request,timeout):
   parts=request.full_url.split('/workers/scripts/',1)[1];name,tail=parts.split('/',1)
   result=fixture.request(request.get_method(),name,'/'+tail,request.data,request.get_header('Content-type'))
   if direct_lists and request.get_method()=='GET':
    if tail=='versions':result=result['items']
    if tail=='deployments':result=result['deployments']
   raw=json.dumps({'success':True,'errors':None,'messages':None,'result':result}).encode()
   class Response:
    status=200
    def __enter__(response):return response
    def __exit__(response,*args):pass
    def read(response,limit):return raw
   return Response()
 api.opener=Opener();return api
class Tests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.packet=pathlib.Path(self.tmp.name);backend=pathlib.Path(__file__).resolve().parents[2];cli=backend/'feast-proxy/node_modules/wrangler/wrangler-dist/cli.js'
  manifest={'account':h.reviewed.ACCOUNT,'workerNames':list(h.EXPECTED),'wranglerCLI':str(cli),'wranglerSHA256':h.reviewed.sha(cli),'files':{}}
  for folder,source in [('production','feast-production'),('owner','feast-owner-validation')]:
   (self.packet/folder).mkdir();config=json.loads((backend/source/'wrangler.jsonc').read_text());config['main']='worker.js';(self.packet/folder/'wrangler.json').write_text(json.dumps(config));(self.packet/folder/'worker.js').write_text('export default {fetch(){return new Response("reviewed OFF fixture")}}')
   for filename in ['worker.js','wrangler.json']:manifest['files'][folder+'/'+filename]=h.reviewed.sha(self.packet/folder/filename)
  (self.packet/'manifest.json').write_text(json.dumps(manifest))
 def tearDown(self):self.tmp.cleanup()
 def receipt(self):return json.loads((self.packet/'existing-update-receipt.json').read_text())
 def test_preserves_all_bindings_runtime_settings_and_uploads_code_only_before_deployment(self):
  api=MockAPI();before=copy.deepcopy(api.settings);self.assertTrue(h.update(self.packet,api));self.assertEqual(before,api.settings)
  self.assertEqual([e[1] for e in api.events],['/versions?bindings_inherit=strict']*2+['/deployments']*2)
  for name,meta,code in api.uploads:
   self.assertEqual(meta['main_module'],'worker.js');self.assertNotIn('migrations',meta);self.assertNotIn('migration_tag',meta)
   self.assertTrue(all(set(b)=={'name','type'} and b['type']=='inherit' for b in meta['bindings']))
   self.assertEqual(code,(self.packet/('production' if name=='feast-proxy-production' else 'owner')/'worker.js').read_bytes())
   h.same_configuration({'resources':h.checked_resources(name,details(name,h.EXPECTED[name])),'settings':before[name]},h.snapshot(api,name,api.live[name]))
  self.assertEqual(self.receipt()['providerCalls'],0);self.assertFalse(self.receipt()['flagsChanged']);self.assertFalse(self.receipt()['ledgerAccessed'])
 def test_version_mismatch_or_staged_latest_stops_before_writing(self):
  api=MockAPI();api.live['feast-proxy-production']=uid(99);self.assertFalse(h.update(self.packet,api));self.assertEqual(api.events,[])
 def test_namespace_mismatch_stops_before_any_write(self):
  api=MockAPI();view=api.versions['feast-proxy-production'][h.EXPECTED['feast-proxy-production']];view['resources']['bindings'][-1]['namespace_id']='wrong';self.assertFalse(h.update(self.packet,api));self.assertEqual(api.events,[]);self.assertEqual(self.receipt()['validationCode'],'namespace drift')
 def test_live_dispatch_or_private_rpc_change_stops_before_any_write(self):
  api=MockAPI();view=api.versions['feast-owner-validation'][h.EXPECTED['feast-owner-validation']];view['resources']['bindings'][-1]['entrypoint']='Wrong';self.assertFalse(h.update(self.packet,api));self.assertEqual(api.events,[])
 def test_unknown_upload_never_retries_or_prints_raw_error(self):
  api=MockAPI();api.fail_write=True;self.assertFalse(h.update(self.packet,api));self.assertEqual(len(api.events),1);self.assertEqual(self.receipt()['state'],'uncertain-stop-inspect-no-retry');self.assertFalse(h.update(self.packet,api));self.assertEqual(len(api.events),1)
  self.assertNotIn('fake-token-sentinel',(self.packet/'existing-update-receipt.json').read_text())
 def test_staged_binding_drift_prevents_all_activation(self):
  api=MockAPI();api.alter_stage=True;self.assertFalse(h.update(self.packet,api));self.assertEqual(len(api.events),1);self.assertEqual(api.live,h.EXPECTED)
 def test_reject_secret_material_and_unreviewed_runtime_before_write(self):
  api=MockAPI();view=api.versions['feast-proxy-production'][h.EXPECTED['feast-proxy-production']];view['resources']['bindings'][-2]['text']='fake-secret';self.assertFalse(h.update(self.packet,api));self.assertEqual(api.events,[]);self.assertNotIn('fake-secret',(self.packet/'existing-update-receipt.json').read_text())
 def test_packet_tampering_rejected_offline(self):
  (self.packet/'production/worker.js').write_text('tampered')
  with self.assertRaises(ValueError):h.update(self.packet,MockAPI())
 def test_concurrent_drift_after_first_staging_stops_no_activation(self):
  api=MockAPI();api.drift=True;self.assertFalse(h.update(self.packet,api));self.assertEqual(len(api.events),1)
 def test_live_or_unapplied_upload_is_not_an_update_candidate(self):
  api=MockAPI();api.versions['feast-owner-validation'][h.EXPECTED['feast-owner-validation']]['resources']['bindings'][0]['text']='true';self.assertFalse(h.update(self.packet,api));self.assertEqual(api.events,[])
 def test_existing_newer_undeployed_version_is_not_overwritten(self):
  api=MockAPI();api.newest['feast-owner-validation']=uid(999);self.assertFalse(h.update(self.packet,api));self.assertEqual(api.events,[])
 def test_deleted_export_or_unknown_runtime_cannot_migrate_namespace(self):
  api=MockAPI();v=api.versions['feast-proxy-production'][h.EXPECTED['feast-proxy-production']];v['resources']['script_runtime']['exports']['ProductionLedger']['state']='deleted';self.assertFalse(h.update(self.packet,api));self.assertEqual(api.events,[])
 def test_auth_failure_logs_only_method_path_status_numeric_codes_and_no_writes(self):
  token='cfat_offline_fixture_not_a_real_token';api=h.API(token)
  class Opener:
   def __init__(self):self.requests=[]
   def open(inner,request,timeout):
    inner.requests.append(request);self.assertEqual(request.get_header('Authorization'),'Bearer '+token)
    if len(inner.requests)==1:
     class Response:
      status=200
      def __enter__(response):return response
      def __exit__(response,*args):pass
      def read(response,limit):return json.dumps({'success':True,'result':{'deployments':[{'versions':[{'version_id':h.EXPECTED['feast-proxy-production'],'percentage':100}]}]}}).encode()
     return Response()
    raw=json.dumps({'success':False,'errors':[{'code':10000,'message':'PRIVATE_ERROR '+token}]}).encode()
    raise urllib.error.HTTPError(request.full_url,401,'PRIVATE_HTTP_REASON',{},io.BytesIO(raw))
  api.opener=Opener();self.assertFalse(h.update(self.packet,api));receipt=self.receipt();self.assertEqual(receipt['state'],'preflight-stopped-no-write');self.assertEqual(receipt['requests'][0]['status'],200);event=receipt['requests'][1]
  self.assertEqual(event['method'],'GET');self.assertTrue(event['path'].endswith('/feast-proxy-production/versions'));self.assertEqual(event['status'],401);self.assertEqual(event['cloudflareErrorCodes'],[10000]);self.assertTrue(all(r.get_method()=='GET' for r in api.opener.requests))
  text=(self.packet/'existing-update-receipt.json').read_text();self.assertNotIn(token,text);self.assertNotIn('PRIVATE_',text);self.assertNotIn('Authorization',text)
 def test_explicit_next_attempt_preserves_failed_receipt_byte_for_byte(self):
  api=MockAPI();api.live['feast-proxy-production']=uid(99);self.assertFalse(h.update(self.packet,api));old=(self.packet/'existing-update-receipt.json').read_bytes()
  self.assertTrue(h.update(self.packet,MockAPI(),attempt=2));self.assertEqual((self.packet/'existing-update-receipt.json').read_bytes(),old)
  new=json.loads((self.packet/'existing-update-receipt-attempt-2.json').read_text());self.assertEqual(new['previousReceiptSHA256']['existing-update-receipt.json'],h.hashlib.sha256(old).hexdigest())
 def test_next_attempt_refuses_any_uncertain_prior_write(self):
  api=MockAPI();api.fail_write=True;self.assertFalse(h.update(self.packet,api));other=MockAPI();self.assertFalse(h.update(self.packet,other,attempt=2));self.assertEqual(other.events,[])
 def test_non_json_auth_failure_never_persists_response_text(self):
  api=h.API('offline-token');events=[];api.on_event=events.append
  class Opener:
   def open(self,request,timeout):raise urllib.error.HTTPError(request.full_url,401,'PRIVATE_REASON',{},io.BytesIO(b'PRIVATE_HTML_ERROR'))
  api.opener=Opener()
  with self.assertRaises(urllib.error.HTTPError):api.request('GET','feast-proxy-production','/deployments')
  self.assertEqual(events[0]['status'],401);self.assertEqual(events[0]['cloudflareErrorCodes'],[]);self.assertNotIn('PRIVATE',json.dumps(events))
 def test_version_lists_accept_documented_order_and_optional_null_numbers(self):
  rows=[{'id':uid(2),'number':None},{'id':uid(1),'number':5}]
  class Versions:
   def __init__(inner,result):inner.result=result
   def request(inner,*args):return inner.result
  for result in [rows,{'items':rows}]:self.assertEqual(h.latest(Versions(result),'feast-proxy-production'),uid(2))
  for result in [None,{},[],{'items':None},{'items':{}},{'items':'bad'},['bad'],[{'number':1}],[{'id':uid(1),'number':'1'}],[{'id':uid(1)},{'id':uid(1)}],[{'id':uid(1),'number':1},{'id':uid(2),'number':2}]]:
   with self.assertRaises(ValueError):h.latest(Versions(result),'feast-proxy-production')
 def test_deployment_lists_support_wrapped_or_array_and_reject_malformed(self):
  class Deployments:
   def __init__(inner,result):inner.result=result
   def request(inner,*args):return inner.result
  rows=[{'versions':[{'version_id':uid(1),'percentage':100}]}]
  for result in [rows,{'deployments':rows}]:self.assertEqual(h.active(Deployments(result),'feast-proxy-production'),uid(1))
  for result in [None,{},[],{'deployments':{}},[{'versions':None}],[{'versions':[{'version_id':uid(1),'percentage':50}]}]]:
   with self.assertRaises(ValueError):h.active(Deployments(result),'feast-proxy-production')
 def test_full_http_envelopes_with_null_errors_complete_all_guards_and_preserve_state(self):
  fixture=MockAPI();api=h.API('cfat_offline_fixture_not_a_real_token')
  class Opener:
   def open(inner,request,timeout):
    parts=request.full_url.split('/workers/scripts/',1)[1];name,tail=parts.split('/',1)
    result=fixture.request(request.get_method(),name,'/'+tail,request.data,request.get_header('Content-type'))
    raw=json.dumps({'success':True,'errors':None,'messages':None,'result':result}).encode()
    class Response:
     status=200
     def __enter__(response):return response
     def __exit__(response,*args):pass
     def read(response,limit):return raw
    return Response()
  api.opener=Opener();self.assertTrue(h.update(self.packet,api));self.assertEqual(self.receipt()['state'],'updated-off-needs-public-health-verification');self.assertEqual(len(fixture.events),4)
 def test_successful_version_read_accepts_null_error_list(self):
  api=h.API('offline-token');events=[];api.on_event=events.append
  class Opener:
   def open(inner,request,timeout):
    class Response:
     status=200
     def __enter__(response):return response
     def __exit__(response,*args):pass
     def read(response,limit):return json.dumps({'success':True,'errors':None,'result':{'items':[{'id':uid(1),'number':None}]}}).encode()
    return Response()
  api.opener=Opener();self.assertEqual(h.latest(api,'feast-proxy-production'),uid(1));self.assertEqual(events[0]['resultShape']['itemsType'],'list')
 def test_full_wire_nullable_settings_and_runtime_matrix_preserves_configuration(self):
  for direct in [False,True]:
   with self.subTest(directLists=direct),tempfile.TemporaryDirectory() as tmp:
    packet=pathlib.Path(tmp)/'packet';shutil.copytree(self.packet,packet);fixture=MockAPI()
    for name in h.EXPECTED:
     fixture.settings[name]={'logpush':None,'observability':None,'tags':None,'tail_consumers':None}
     runtime=fixture.versions[name][h.EXPECTED[name]]['resources']['script_runtime'];runtime['compatibility_flags']=None;runtime['limits']=None;runtime['exports']=None
     if name=='feast-owner-validation':runtime['migration_tag']=None
    original=copy.deepcopy(fixture.settings);self.assertTrue(h.update(packet,wire_api(fixture,direct)));self.assertEqual(fixture.settings,original);self.assertEqual(len(fixture.events),4)
    for _,metadata,_ in fixture.uploads:self.assertNotIn('migration_tag',metadata);self.assertNotIn('migrations',metadata);self.assertNotIn('exports',metadata)
 def test_full_wire_malformed_settings_resources_matrix_stops_before_any_write(self):
  def mutate(fixture,case):
   name='feast-proxy-production';resources=fixture.versions[name][h.EXPECTED[name]]['resources']
   if case=='whole-settings-null':fixture.settings[name]=None
   elif case=='obs-array':fixture.settings[name]['observability']=[]
   elif case=='obs-enabled':fixture.settings[name]['observability']={'enabled':True}
   elif case=='unknown-enabled':fixture.settings[name]['observability']={'enabled':None}
   elif case=='logpush-string':fixture.settings[name]['logpush']='false'
   elif case=='binding-object':resources['bindings']={}
   elif case=='script-null':resources['script']=None
   elif case=='runtime-null':resources['script_runtime']=None
   elif case=='exports-array':resources['script_runtime']['exports']=[]
   elif case=='flags-object':resources['script_runtime']['compatibility_flags']={}
   elif case=='limits-array':resources['script_runtime']['limits']=[]
   elif case=='limits-bool':resources['script_runtime']['limits']={'cpu_ms':True}
   elif case=='usage-unknown':resources['script_runtime']['usage_model']='unknown'
   elif case=='migration-unknown':resources['script_runtime']['migration_tag']='unexpected'
  cases=['whole-settings-null','obs-array','obs-enabled','unknown-enabled','logpush-string','binding-object','script-null','runtime-null','exports-array','flags-object','limits-array','limits-bool','usage-unknown','migration-unknown']
  for case in cases:
   with self.subTest(case=case),tempfile.TemporaryDirectory() as tmp:
    packet=pathlib.Path(tmp)/'packet';shutil.copytree(self.packet,packet);fixture=MockAPI();mutate(fixture,case);self.assertFalse(h.update(packet,wire_api(fixture)));self.assertEqual(fixture.events,[])
    receipt=json.loads((packet/'existing-update-receipt.json').read_text());self.assertEqual(receipt['state'],'preflight-stopped-no-write');self.assertEqual(receipt['failureType'],'SafeStop');self.assertTrue(receipt['validationCode'])
class RepairContracts(unittest.TestCase):
 setUp=Tests.setUp
 tearDown=Tests.tearDown
 receipt=Tests.receipt
 def test_export_reconciliation_requires_verified_empty_result(self):
  meta={'exports':{'ProductionLedger':{'state':'created'}}}
  for result in [{'id':uid(1)},{'id':uid(1),'exports_reconciliation':None},{'id':uid(1),'exports_reconciliation':{'created':['ProductionLedger']}},{'id':uid(1),'exports_reconciliation':{'warnings':[{}]}},{'id':uid(1),'exports_reconciliation':{'unknown':[]}}]:
   with self.assertRaises(h.SafeStop):h.checked_upload(result,meta)
  self.assertEqual(h.checked_upload({'id':uid(1),'exports_reconciliation':empty_reconciliation()},meta),uid(1))
 def test_acknowledgement_and_read_only_poll_contract(self):
  for result in [None,{}, {'id':uid(2)}, {'id':uid(2),'strategy':'percentage','versions':[{'version_id':uid(9),'percentage':100}]}]:
   with self.assertRaises(h.SafeStop):h.checked_ack(result,uid(1))
  class Lag:
   def __init__(self):self.calls=0
   def request(self,method,*args):
    assert method=='GET';self.calls+=1
    return [{'versions':[{'version_id':uid(1 if self.calls<3 else 2),'percentage':100}]}]
  api=Lag();h.await_active(api,'feast-proxy-production',uid(1),uid(2),pause=lambda _:None);self.assertEqual(api.calls,3)
  with self.assertRaises(h.SafeStop):h.await_active(Lag(),'feast-proxy-production',uid(1),uid(2),polls=2,pause=lambda _:None)
 def test_final_pair_detects_production_drift_after_owner_activation(self):
  class Drift(MockAPI):
   def request(self,method,name,suffix='',body=None,content_type=None):
    result=super().request(method,name,suffix,body,content_type)
    if method=='POST' and name=='feast-owner-validation' and suffix=='/deployments':self.live['feast-proxy-production']=h.EXPECTED['feast-proxy-production']
    return result
  api=Drift();self.assertFalse(h.update(self.packet,api));self.assertIsNone(self.receipt()['preservationVerified']);self.assertEqual(self.receipt()['state'],'uncertain-stop-inspect-no-retry')
 def test_bad_submitted_metadata_is_not_assumed_preserved_by_fixture(self):
  from unittest.mock import patch
  with patch.object(h,'metadata',return_value={'main_module':'worker.js','bindings':[]}):
   api=MockAPI();self.assertFalse(h.update(self.packet,api));self.assertEqual(len(api.events),1);self.assertEqual(api.live,h.EXPECTED)
 def test_atomic_receipt_replace_failure_keeps_previous_json(self):
  from unittest.mock import patch
  path=self.packet/'atomic.json';h.atomic_receipt(path,{'state':'before'})
  with patch.object(h.os,'replace',side_effect=OSError('offline failure')):
   with self.assertRaises(OSError):h.atomic_receipt(path,{'state':'after'})
  self.assertEqual(json.loads(path.read_text()),{'state':'before'})
 def test_wrong_export_types_and_incomplete_reconciliation_fail_before_activation(self):
  for export,kind in [('ProductionLedger','worker'),('OwnerValidationRPC','durable-object')]:
   api=MockAPI();api.versions['feast-proxy-production'][h.EXPECTED['feast-proxy-production']]['resources']['script_runtime']['exports'][export]['type']=kind
   self.assertFalse(h.update(self.packet,api));self.assertEqual(api.events,[])
  with self.assertRaises(h.SafeStop):h.checked_upload({'id':uid(1),'exports_reconciliation':{}},{'exports':{'ProductionLedger':{}}})
 def test_malformed_ack_stops_without_claiming_deployment_or_retry(self):
  class BadAck(MockAPI):
   def request(self,method,name,suffix='',body=None,content_type=None):
    result=super().request(method,name,suffix,body,content_type)
    return {'id':uid(200)} if method=='POST' and suffix=='/deployments' else result
  api=BadAck();self.assertFalse(h.update(self.packet,api));self.assertEqual(len(api.events),3);self.assertEqual(self.receipt()['deployedVersions'],{});self.assertFalse(h.update(self.packet,api));self.assertEqual(len(api.events),3)
 def test_unexpected_poll_version_stops_immediately(self):
  class Foreign:
   def request(self,*args):return [{'versions':[{'version_id':uid(9),'percentage':100}]}]
  with self.assertRaises(h.SafeStop):h.await_active(Foreign(),'feast-proxy-production',uid(1),uid(2),pause=lambda _:self.fail('must not wait'))

if __name__=='__main__':unittest.main()
