import copy,datetime,importlib.util,json,pathlib,unittest
from unittest.mock import patch
base=pathlib.Path(__file__).parent
def load(name,file):
 s=importlib.util.spec_from_file_location(name,base/file);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
h=load('renew','renew-owner-access.py');fixture=load('live','test_update_production_code.py');f=fixture.f
class API(fixture.LiveAPI):
 def request(self,method,name,suffix='',body=None,content_type=None):
  result=f.MockAPI.request(self,method,name,suffix,body,content_type)
  if method=='POST' and suffix.startswith('/versions?'):
   for b in self.versions[name][result['id']]['resources']['bindings']:
    if b['type']=='secret_text':b.pop('text',None)
  return result
class Tests(unittest.TestCase):
 setUp=f.Tests.setUp
 tearDown=f.Tests.tearDown
 def prepare(self):
  now=datetime.datetime.now(datetime.timezone.utc);r={'id':'owner-original-iphone17','sha256':'a'*64,'createdAt':now.isoformat(),'expiresAt':(now+datetime.timedelta(days=30)).isoformat()};(self.packet/'owner-hash.json').write_text(json.dumps([r]));return r
 def run_case(self,api):
  self.prepare()
  with patch.object(h,'EXPECTED',dict(h.u.EXPECTED)),patch.object(h,'OWNER_SHA',h.u.hashlib.sha256((self.packet/'owner/worker.js').read_bytes()).hexdigest()):return h.run(api,self.packet,pause=lambda _:None)
 def test_success_only_owner_hash_code_changes(self):
  api=API();production=copy.deepcopy(api.versions[h.p.PRODUCTION]);settings=copy.deepcopy(api.settings)
  self.assertTrue(self.run_case(api));self.assertEqual(api.events,[(h.p.OWNER,'/versions?bindings_inherit=strict'),(h.p.OWNER,'/deployments')]);self.assertEqual(production,api.versions[h.p.PRODUCTION]);self.assertEqual(settings,api.settings)
  meta=api.uploads[0][1];changed=[b for b in meta['bindings'] if b['type']!='inherit'];self.assertEqual([x['name'] for x in changed],['OWNER_TOKEN_HASHES_JSON']);self.assertEqual(json.loads(changed[0]['text'])[0]['id'],'owner-original-iphone17')
 def test_preflight_drift_no_write(self):
  api=API();api.live[h.p.OWNER]=f.uid(999);self.assertFalse(self.run_case(api));self.assertEqual(api.events,[])
 def test_uncertain_upload_never_repeat(self):
  api=API();api.fail_write=True;self.assertFalse(self.run_case(api));self.assertEqual(len(api.events),1);self.assertEqual(json.loads((self.packet/'renewal-receipt.json').read_text())['state'],'uncertain-reconcile-before-retry')
 def test_record_duration_scope_and_expiry(self):
  r=self.prepare();now=datetime.datetime.now(datetime.timezone.utc);self.assertEqual(h.record(json.dumps([r]),now),[r])
  for bad in [{**r,'id':'other'},{**r,'token':'raw'},{**r,'expiresAt':(now+datetime.timedelta(days=31)).isoformat()},{**r,'createdAt':(now+datetime.timedelta(days=1)).isoformat()}]:
   with self.assertRaises(ValueError):h.record(json.dumps([bad]),now)
 def test_production_write_rejected_before_transport(self):
  with self.assertRaises(ValueError):h.OwnerAPI('offline').request('POST',h.p.PRODUCTION,'/deployments')
if __name__=='__main__':unittest.main()
