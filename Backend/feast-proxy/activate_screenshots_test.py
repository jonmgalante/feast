import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import activate_screenshots as s

class ScreenshotActivationTests(unittest.TestCase):
    def result(self):
        return {'httpStatus':200,'accepted':True,'model':'gpt-6-luna','candidateCount':0,
                'extractionVerified':True,'noCollectionCandidates':True,
                'budget':{'reservedMicroUSD':500000,'userReservedMicroUSD':500000}}
    def test_activation_requires_extraction_native_acceptance_no_collection_and_preserved_budget(self):
        old={'reservedMicroUSD':450000,'userReservedMicroUSD':450000}
        self.assertTrue(s.valid_image_result(self.result(),old))
        for key,value in [('httpStatus',502),('accepted',False),('extractionVerified',False),('noCollectionCandidates',False),('model','other'),('candidateCount',1)]:
            bad=self.result();bad[key]=value;self.assertFalse(s.valid_image_result(bad,old))
        for total,user in [(450000,500000),(500000,450000),(5050000,500000),(500000,2550000)]:
            bad=self.result();bad['budget']={'reservedMicroUSD':total,'userReservedMicroUSD':user}
            self.assertFalse(s.valid_image_result(bad,old))
    def test_deploy_inherits_existing_secrets_and_same_ledger_without_credential_operations(self):
        bindings=[{'name':'BUDGET','type':'durable_object_namespace','namespace_id':'existing'},
                  {'name':'OPENAI_API_KEY','type':'secret_text'},{'name':'CLIENT_TOKEN_HASHES_JSON','type':'secret_text'}]
        def deployed(token,active,**kw):
            config=json.loads(Path(kw['config_path']).read_text())['env']['dev']
            self.assertEqual(config['vars']['ALLOW_SELECTED_SCREENSHOT'],'verification')
            self.assertEqual(config['vars']['ALLOW_SAVED_METADATA'],'true')
            self.assertEqual(config['unsafe']['bindings'],[{'name':'OPENAI_API_KEY','type':'inherit'},{'name':'CLIENT_TOKEN_HASHES_JSON','type':'inherit'}])
            self.assertEqual(config['migrations'],[{'tag':'v1','new_sqlite_classes':['BudgetLedger']}])
            return 'new'
        with patch.object(s.d,'deployment_state',return_value=[('old',100)]),patch.object(s.d,'latest_id',return_value='old'),patch.object(s.d,'fetch_json',return_value={'resources':{'bindings':bindings}}),patch.object(s.d,'run_deploy',side_effect=deployed):
            self.assertEqual(s.deploy('public-fake','old','verification'),'new')
    def test_namespace_drift_stops_before_any_image_request(self):
        before={'resources':{'bindings':[{'name':'BUDGET','namespace_id':'old'},{'name':'OPENAI_API_KEY','type':'secret_text'},{'name':'CLIENT_TOKEN_HASHES_JSON','type':'secret_text'}]}}
        after=copy.deepcopy(before);after['resources']['bindings'][0]['namespace_id']='changed'
        with patch.object(s.d,'deployment_state',return_value=[('old',100)]),patch.object(s.d,'latest_id',return_value='old'),patch.object(s.d,'fetch_json',side_effect=[before,after]),patch.object(s.d,'run_deploy',return_value='new'):
            with self.assertRaises(s.d.Stop):s.deploy('public-fake','old','verification')
    def test_jpeg_size_metadata_and_dimensions_are_checked_without_private_images(self):
        # Small non-private structural fixture: SOF (800x480), then SOS.
        jpeg=b'\xff\xd8\xff\xc0\x00\x0b\x08\x01\xe0\x03\x20\x01\x01\x11\x00\xff\xda\x00\x08'
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'public.jpg';p.write_bytes(jpeg)
            self.assertEqual(s.verify_public_image(p)['width'],800)
            p.write_bytes(jpeg[:2]+b'\xff\xe1\x00\x04xx'+jpeg[2:])
            with self.assertRaises(s.d.Stop):s.verify_public_image(p)
            p.write_bytes(b'x'*196609)
            with self.assertRaises(s.d.Stop):s.verify_public_image(p)
    def test_noninteractive_stops_without_prompt_or_deploy(self):
        with patch.object(s.d,'verify_configuration'),patch.object(s.sys.stdin,'isatty',return_value=False),patch.object(s.getpass,'getpass') as prompt,patch.object(s,'deploy') as deploy:
            with self.assertRaises(s.d.Stop):s.main()
            prompt.assert_not_called();deploy.assert_not_called()

if __name__=='__main__':unittest.main()
