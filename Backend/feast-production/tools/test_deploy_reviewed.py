import importlib.util,json,pathlib,tempfile,unittest,subprocess
spec=importlib.util.spec_from_file_location('helper',pathlib.Path(__file__).with_name('deploy-reviewed.py'));h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class Tests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temp.name);repo=pathlib.Path(__file__).resolve().parents[2];self.cli=repo/'feast-proxy/node_modules/wrangler/wrangler-dist/cli.js'
  self.m={'account':h.ACCOUNT,'workerNames':list(h.NAMES),'wranglerCLI':str(self.cli),'wranglerSHA256':h.sha(self.cli),'files':{}}
  for folder,source in [('production','feast-production'),('owner','feast-owner-validation')]:
   (self.root/folder).mkdir();c=json.loads((repo/source/'wrangler.jsonc').read_text());c['main']='worker.js'
   (self.root/folder/'wrangler.json').write_text(json.dumps(c));(self.root/folder/'worker.js').write_text('export default {fetch(){return new Response("disabled")}}')
   for name in ['worker.js','wrangler.json']:self.m['files'][folder+'/'+name]=h.sha(self.root/folder/name)
  (self.root/'manifest.json').write_text(json.dumps(self.m))
 def tearDown(self):self.temp.cleanup()
 def test_inspect_and_tamper(self):
  h.inspect(self.root);(self.root/'production/worker.js').write_text('changed')
  with self.assertRaises(ValueError):h.inspect(self.root)
 def test_no_secret_in_command_receipt_or_logs(self):
  token='offline-fixture-not-a-real-token';calls=[]
  def run(args,**kw):
   self.assertNotIn(token,' '.join(args));self.assertEqual(kw['env']['CLOUDFLARE_API_TOKEN'],token);self.assertEqual(pathlib.Path(kw['env']['WRANGLER_LOG_PATH']).resolve(),pathlib.Path('/dev/null'));calls.append(args)
   return subprocess.CompletedProcess(args,0,'Current Version ID: 00000000-0000-4000-8000-000000000001\n'+token,token)
  self.assertTrue(h.deploy(self.root,self.m,self.cli,token,run));self.assertEqual(len(calls),2)
  for path in self.root.rglob('*'):
   if path.is_file():self.assertNotIn(token,path.read_text())
 def test_uncertain_stops_no_repeat(self):
  calls=[]
  def run(args,**kw):calls.append(args);return subprocess.CompletedProcess(args,1,'uncertain','')
  self.assertFalse(h.deploy(self.root,self.m,self.cli,'offline-token',run));self.assertEqual(len(calls),1)
  self.assertFalse(h.deploy(self.root,self.m,self.cli,'offline-token',run));self.assertEqual(len(calls),1)
  self.assertTrue(json.loads((self.root/'deployment-receipt.json').read_text())['state'].startswith('uncertain'))
 def test_activation_or_storage_scope_change_rejected(self):
  p=self.root/'production/wrangler.json';c=json.loads(p.read_text());c['vars']['LIVE_AI']='true';p.write_text(json.dumps(c));self.m['files']['production/wrangler.json']=h.sha(p);(self.root/'manifest.json').write_text(json.dumps(self.m))
  with self.assertRaises(ValueError):h.inspect(self.root)
 def test_exact_recovery_off_scaffold_and_legacy_packet_supported(self):
  h.inspect(self.root)
  p=self.root/'production/wrangler.json';c=json.loads(p.read_text())
  del c['vars']['ASK_FEAST_RECOVERY_ENABLED'];c['durable_objects']['bindings'].pop();c['migrations'].pop()
  p.write_text(json.dumps(c));self.m['files']['production/wrangler.json']=h.sha(p);(self.root/'manifest.json').write_text(json.dumps(self.m));h.inspect(self.root)
 def test_recovery_schema_is_atomic_and_rejects_new_permissions_storage_and_activation(self):
  p=self.root/'production/wrangler.json';original=json.loads(p.read_text())
  for bad in ['enabled','missing-flag','missing-binding','missing-migration','wrong-class','extra-binding','changed-ledger','extra-migration']:
   with self.subTest(bad=bad):
    c=json.loads(json.dumps(original))
    if bad=='enabled':c['vars']['ASK_FEAST_RECOVERY_ENABLED']='true'
    if bad=='missing-flag':del c['vars']['ASK_FEAST_RECOVERY_ENABLED']
    if bad=='missing-binding':c['durable_objects']['bindings'].pop()
    if bad=='missing-migration':c['migrations'].pop()
    if bad=='wrong-class':c['durable_objects']['bindings'][1]['class_name']='Replacement'
    if bad=='extra-binding':c['durable_objects']['bindings'].append({'name':'EXTRA','class_name':'Extra'})
    if bad=='changed-ledger':c['migrations'][0]['tag']='replacement'
    if bad=='extra-migration':c['migrations'].append({'tag':'unreviewed','new_sqlite_classes':['Extra']})
    p.write_text(json.dumps(c));self.m['files']['production/wrangler.json']=h.sha(p);(self.root/'manifest.json').write_text(json.dumps(self.m))
    with self.assertRaises(ValueError):h.inspect(self.root)
if __name__=='__main__':unittest.main()
