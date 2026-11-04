import copy,datetime,importlib.util,json,pathlib,subprocess,tempfile,unittest
spec=importlib.util.spec_from_file_location('stage',pathlib.Path(__file__).with_name('stage-owner-secrets.py'));h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class Tests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.packet=pathlib.Path(self.temp.name);self.root=pathlib.Path(__file__).resolve().parents[2];self.cli=self.root/'feast-proxy/node_modules/wrangler/wrangler-dist/cli.js';self.original=h.reviewed.inspect;h.reviewed.inspect=lambda _:None
  self.deployed={name:'00000000-0000-4000-8000-00000000000'+str(i+1) for i,name in enumerate(h.reviewed.NAMES)};self.views={};self.versions={};self.writes=[];self.calls=[]
  (self.packet/'deployment-receipt.json').write_text(json.dumps({'state':'deployed-disabled-needs-health-verification','versions':self.deployed}))
  for folder,name in zip(('production','owner'),h.reviewed.NAMES):
   (self.packet/folder).mkdir();c=json.loads((self.root/('feast-production' if folder=='production' else 'feast-owner-validation')/'wrangler.jsonc').read_text());(self.packet/folder/'wrangler.json').write_text(json.dumps(c));bindings=[{'type':'plain_text','name':k,'text':v} for k,v in c['vars'].items()];self.views[self.deployed[name]]={'id':self.deployed[name],'resources':{'bindings':bindings,'script':{'etag':'unchanged-code'},'script_runtime':{'compatibility_date':'2026-10-20'}}};self.versions[folder]=[{'id':self.deployed[name],'metadata':{'created_on':'2026-10-27T00:00:00Z'}}]
 def tearDown(self):h.reviewed.inspect=self.original;self.temp.cleanup()
 def run_cli(self,args,**kwargs):
  self.calls.append(args);folder=kwargs['cwd'].name;name=h.reviewed.NAMES[0 if folder=='production' else 1];self.assertNotIn('offline-cloudflare',' '.join(args));self.assertNotIn('sk-offline',' '.join(args));self.assertEqual(pathlib.Path(kwargs['env']['WRANGLER_LOG_PATH']).resolve(),pathlib.Path('/dev/null'));cmd=args[2:args.index('--config')]
  if cmd==['deployments','list','--json']:out=[{'created_on':'2026-10-27T00:00:00Z','versions':[{'version_id':self.deployed[name],'percentage':100}]}]
  elif cmd==['versions','list','--json']:out=self.versions[folder]
  elif cmd[:2]==['versions','view']:out=self.views[cmd[2]]
  elif cmd[:3]==['versions','secret','put']:
   secret=cmd[3];self.writes.append((name,secret));self.assertIn('input',kwargs);version='10000000-0000-4000-8000-00000000000'+str(len(self.writes));view=copy.deepcopy(self.views[self.deployed[name]]);view['id']=version;view['resources']['bindings'].append({'type':'secret_text','name':secret});self.views[version]=view;self.versions[folder].append({'id':version,'metadata':{'created_on':'2026-10-27T01:00:00Z'}});return subprocess.CompletedProcess(args,0,'Success! Created version '+version+' with secret '+secret+'.','')
  else:raise AssertionError('unexpected command')
  return subprocess.CompletedProcess(args,0,json.dumps(out),'')
 def test_stage_only_no_activation_or_secret_artifact(self):
  self.assertTrue(h.stage(self.packet,self.cli,'offline-cloudflare','sk-offline','hash-only-metadata',self.run_cli));self.assertEqual(self.writes,[(h.reviewed.NAMES[0],'OPENAI_API_KEY'),(h.reviewed.NAMES[1],'OWNER_TOKEN_HASHES_JSON')]);r=json.loads((self.packet/'secret-staging-receipt.json').read_text());self.assertFalse(r['activation']);self.assertEqual(r['providerCalls'],0)
  for p in self.packet.rglob('*'):
   if p.is_file():self.assertNotIn('offline-cloudflare',p.read_text());self.assertNotIn('sk-offline',p.read_text())
  before=len(self.calls);self.assertFalse(h.stage(self.packet,self.cli,'offline-cloudflare','sk-offline','hash-only-metadata',self.run_cli));self.assertEqual(len(self.calls),before)
 def test_remote_drift_before_writes_stops(self):
  self.versions['owner'].append({'id':'unexpected','metadata':{'created_on':'2026-10-27T02:00:00Z'}});self.assertFalse(h.stage(self.packet,self.cli,'offline-cloudflare','sk-offline','hash-only',self.run_cli));self.assertEqual(self.writes,[])
 def test_uncertain_write_never_repeats_or_activates(self):
  def run(args,**kw):
   if args[2:5]==['versions','secret','put']:self.writes.append(('uncertain','secret'));raise subprocess.TimeoutExpired(args,120)
   return self.run_cli(args,**kw)
  self.assertFalse(h.stage(self.packet,self.cli,'offline-cloudflare','sk-offline','hash-only',run));self.assertEqual(len(self.writes),1);self.assertEqual(json.loads((self.packet/'secret-staging-receipt.json').read_text())['state'],'uncertain-stop-inspect-versions-no-retry')
 def test_hash_metadata_exact_scope_expiry_no_raw_token(self):
  now=datetime.datetime(2026,10,27,tzinfo=datetime.timezone.utc);r={'id':'owner-original-iphone17','sha256':'a'*64,'createdAt':now.isoformat(),'expiresAt':(now+datetime.timedelta(hours=48)).isoformat()};self.assertEqual(json.loads(h.owner_record([r],now)),[r])
  for bad in [{**r,'token':'raw'},{**r,'id':'other-device'},{**r,'expiresAt':(now+datetime.timedelta(hours=49)).isoformat()},{**r,'expiresAt':now.isoformat()}]:
   with self.assertRaises(ValueError):h.owner_record([bad],now)
 def test_resource_or_other_binding_change_rejected(self):
  a={'resources':{'bindings':[{'type':'plain_text','name':'LIVE_AI','text':'false'}],'script':{'etag':'same'}}};b=copy.deepcopy(a);b['resources']['bindings'].append({'type':'secret_text','name':'OPENAI_API_KEY'});h.metadata_matches(a,b,'OPENAI_API_KEY');b['resources']['bindings'][0]['text']='true'
  with self.assertRaises(ValueError):h.metadata_matches(a,b,'OPENAI_API_KEY')
if __name__=='__main__':unittest.main()
