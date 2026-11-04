import json
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
import deploy_dev as d

class HandoffTests(unittest.TestCase):
    def test_reviewed_configuration(self):
        d.verify_configuration()

    def test_read_status_cannot_redirect_the_existing_lifetime_namespace(self):
        original = Path.read_text
        def changed(path, *args, **kwargs):
            value = original(path, *args, **kwargs)
            return value.replace("idFromName('shared-lifetime-v1')", "idFromName('different-lifetime')", 1) if path.name == 'worker.mjs' else value
        with patch.object(Path, 'read_text', changed):
            with self.assertRaises(d.Stop): d.verify_configuration()

    def test_staged_secret_must_exist(self):
        with patch.object(d, 'latest_id', return_value=d.STAGED), patch.object(d,'fetch_json',return_value={'resources':{'bindings':[]}}):
            with self.assertRaises(d.Stop): d.preflight('fake-test-token')

    def test_version_drift_stops_before_secret_or_deploy(self):
        with patch.object(d,'latest_id',return_value='changed'), patch.object(d,'fetch_json') as fetch:
            with self.assertRaises(d.Stop): d.preflight('fake-test-token')
            fetch.assert_not_called()

    def test_concurrent_deployment_stops_before_subprocess(self):
        with patch.object(d,'latest_id',return_value=d.STAGED), patch.object(d,'deployment_state',return_value=[('changed',100)]), patch.object(d.subprocess,'run') as run:
            with self.assertRaises(d.Stop): d.run_deploy('fake-test-token',[('304d5bba-test',100)])
            run.assert_not_called()

    def test_secret_metadata_checks_name_and_encryption_type_only(self):
        self.assertTrue(d.secret_exists({'resources':{'bindings':[{'name':'OPENAI_API_KEY','type':'secret_text'}]}}))
        self.assertFalse(d.secret_exists({'resources':{'bindings':[{'name':'OPENAI_API_KEY','type':'plain_text'}]}}))

    def test_token_cannot_be_sent_outside_exact_worker_api(self):
        with self.assertRaises(d.Stop): d.fetch_json('https://example.invalid/', token='fake-test-token')

    def test_noninteractive_invocation_never_prompts_or_calls_api(self):
        with patch.object(d.sys,'argv',['deploy_dev.py']), patch.object(d.sys.stdin,'isatty',return_value=False), patch.object(d.getpass,'getpass') as prompt, patch.object(d,'preflight') as check:
            with self.assertRaises(d.Stop): d.main()
            prompt.assert_not_called();check.assert_not_called()

    def test_hash_file_exact_contract_rejects_raw_token_and_wrong_expiry(self):
        users = [{'id':'feast-dev-tester-one','sha256':'a'*64,'expiresAt':'2026-11-22T14:30:00Z'},
                 {'id':'feast-dev-tester-two','sha256':'b'*64,'expiresAt':'2026-11-22T14:30:00Z'}]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'public-hashes.json'
            path.write_text(json.dumps(users))
            self.assertEqual(len(json.loads(d.client_hashes(path))), 2)
            users[0]['rawToken'] = 'never accepted'
            path.write_text(json.dumps(users))
            with self.assertRaises(d.Stop): d.client_hashes(path)
            del users[0]['rawToken']
            users[0]['expiresAt'] = '2099-01-01T00:00:00Z'
            path.write_text(json.dumps(users))
            with self.assertRaises(d.Stop): d.client_hashes(path)

    def test_concurrent_change_prevents_hash_staging(self):
        with patch.object(d,'latest_id',return_value='changed'), patch.object(d.subprocess,'run') as run:
            with self.assertRaises(d.Stop): d.complete_live('fake-test-token',[],b'[]')
            run.assert_not_called()

    def test_completed_flow_verifies_disabled_before_live(self):
        version = {'resources':{'bindings':[{'name':'OPENAI_API_KEY','type':'secret_text'}, {'name':'CLIENT_TOKEN_HASHES_JSON','type':'secret_text'}]}}
        active = [('304d5bba-old',100)]
        with patch.object(d,'latest_id',side_effect=[d.STAGED,'new-staged']), patch.object(d,'deployment_state',return_value=active), \
             patch.object(d,'fetch_json',return_value=version), patch.object(d.subprocess,'run') as run, \
             patch.object(d,'run_deploy',side_effect=['disabled-version','live-version']) as deploy:
            run.return_value.returncode = 0
            d.complete_live('fake-test-token',active,b'[]')
            self.assertEqual(run.call_args.kwargs['input'],b'[]')
            self.assertFalse(deploy.call_args_list[0].kwargs.get('live',False))
            self.assertTrue(deploy.call_args_list[1].kwargs['live'])
            self.assertEqual(deploy.call_args_list[1].kwargs['expected_latest'],'disabled-version')

    def test_disabled_verification_failure_never_activates_live(self):
        version = {'resources':{'bindings':[{'name':'OPENAI_API_KEY','type':'secret_text'}, {'name':'CLIENT_TOKEN_HASHES_JSON','type':'secret_text'}]}}
        active = [('304d5bba-old',100)]
        with patch.object(d,'latest_id',side_effect=[d.STAGED,'new-staged']), patch.object(d,'deployment_state',return_value=active), \
             patch.object(d,'fetch_json',return_value=version), patch.object(d.subprocess,'run') as run, \
             patch.object(d,'run_deploy',side_effect=d.Stop('disabled health failed')) as deploy:
            run.return_value.returncode = 0
            with self.assertRaises(d.Stop): d.complete_live('fake-test-token',active,b'[]')
            self.assertEqual(deploy.call_count,1)
            self.assertFalse(deploy.call_args.kwargs.get('live',False))

    def test_ledger_namespace_change_blocks_deployment(self):
        config = json.loads((d.ROOT/'wrangler.jsonc').read_text())
        package = json.loads((d.ROOT/'package.json').read_text())
        config['env']['dev']['durable_objects']['bindings'][0]['class_name'] = 'FreshBudget'
        with patch.object(d.json,'loads',side_effect=[config,package]):
            with self.assertRaises(d.Stop): d.verify_configuration()

    def test_get_metadata_retries_without_repeating_mutations(self):
        with patch.object(d,'fetch_json_once',side_effect=[d.Stop('Network/metadata result uncertain'),{'ok':True}]) as fetch, patch.object(d.time,'sleep'):
            self.assertEqual(d.fetch_json(d.BASE+'/versions','fake'),{'ok':True})
            self.assertEqual(fetch.call_count,2)
        with patch.object(d,'fetch_json_once',side_effect=d.Stop('Network/metadata result uncertain')) as fetch:
            with self.assertRaises(d.Stop): d.fetch_json(d.BASE+'/versions','fake',method='POST')
            self.assertEqual(fetch.call_count,1)

    def test_resume_reconciles_active_secrets_before_activation(self):
        version = {'resources':{'bindings':[{'name':'OPENAI_API_KEY','type':'secret_text'}, {'name':'CLIENT_TOKEN_HASHES_JSON','type':'secret_text'}]}}
        health={'service':'feast-proxy','environment':'dev','totalCapMicroUSD':5000000,'liveAI':False,'requestsEnabled':False}
        with patch.object(d,'deployment_state',return_value=[('existing-version',100)]), patch.object(d,'latest_id',return_value='existing-version'), \
             patch.object(d,'fetch_json',side_effect=[version,(200,health)]), patch.object(d,'run_deploy') as deploy, patch.object(Path,'write_text'):
            d.resume_live('fake')
            self.assertEqual(deploy.call_count,1)
            self.assertTrue(deploy.call_args.kwargs['live'])
            self.assertEqual(deploy.call_args.kwargs['expected_latest'],'existing-version')

    def test_resume_rejects_newer_staged_version_without_deploy(self):
        with patch.object(d,'deployment_state',return_value=[('active',100)]),patch.object(d,'latest_id',return_value='other'),patch.object(d,'run_deploy') as deploy:
            with self.assertRaises(d.Stop):d.resume_live('fake')
            deploy.assert_not_called()

    def test_repair_verified_live_baseline_then_one_simulator_check(self):
        baseline='9bcef752-4b6e-4f72-bc7d-3dc0e655a315'
        version={'resources':{'bindings':[{'name':'OPENAI_API_KEY','type':'secret_text'},{'name':'CLIENT_TOKEN_HASHES_JSON','type':'secret_text'}]}}
        health={'service':'feast-proxy','environment':'dev','totalCapMicroUSD':5000000,'liveAI':True,'requestsEnabled':True}
        with patch.object(d,'deployment_state',return_value=[(baseline,100)]),patch.object(d,'latest_id',return_value=baseline), \
             patch.object(d,'fetch_json',side_effect=[version,(200,health)]),patch.object(d,'checked_health'), \
             patch.object(d,'run_deploy',return_value='repaired') as deploy,patch.object(d,'verify_synthetic_simulator') as verify,patch.object(Path,'write_text'):
            d.resume_live('fake-token',repair=True)
            self.assertEqual(deploy.call_count,1)
            self.assertEqual(deploy.call_args.kwargs['expected_latest'],baseline)
            verify.assert_called_once_with('repaired')

    def test_repair_changed_baseline_stops_before_mutation(self):
        version={'resources':{'bindings':[{'name':'OPENAI_API_KEY','type':'secret_text'},{'name':'CLIENT_TOKEN_HASHES_JSON','type':'secret_text'}]}}
        health={'service':'feast-proxy','environment':'dev','totalCapMicroUSD':5000000,'liveAI':True,'requestsEnabled':True}
        with patch.object(d,'deployment_state',return_value=[('changed',100)]),patch.object(d,'latest_id',return_value='changed'), \
             patch.object(d,'fetch_json',side_effect=[version,(200,health)]),patch.object(d,'checked_health'),patch.object(d,'run_deploy') as deploy,patch.object(Path,'write_text'):
            with self.assertRaises(d.Stop):d.resume_live('fake-token',repair=True)
            deploy.assert_not_called()

if __name__=='__main__': unittest.main()
