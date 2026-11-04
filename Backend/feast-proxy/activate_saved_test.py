import copy
import unittest
from unittest.mock import patch
import activate_saved as a

class ReplacementTests(unittest.TestCase):
    def records(self):
        return [{'id':'feast-dev-tester-one','sha256':'a'*64,'expiresAt':a.EXPIRY},
                {'id':'feast-dev-tester-two','sha256':'b'*64,'expiresAt':a.EXPIRY}]
    def test_only_first_hash_changes_second_and_expiry_identical(self):
        old=self.records(); original=copy.deepcopy(old)
        new={'id':'feast-dev-tester-one','sha256':'c'*64,'expiresAt':a.EXPIRY}
        result=a.combine_replacement(old,new)
        self.assertEqual(old,original)
        self.assertEqual(result[1],old[1]);self.assertEqual(result[0]['expiresAt'],old[0]['expiresAt'])
        self.assertEqual({u['id'] for u in result},{u['id'] for u in old})
    def test_expansion_duplicate_or_raw_credentials_rejected(self):
        valid={'id':'feast-dev-tester-one','sha256':'c'*64,'expiresAt':a.EXPIRY}
        for patch_values in [{'id':'third-user'},{'expiresAt':'2099-01-01T00:00:00Z'},{'sha256':'a'*64},{'sha256':'b'*64},{'token':'raw-not-allowed'}]:
            candidate={**valid,**patch_values}
            with self.assertRaises(a.d.Stop):a.combine_replacement(self.records(),candidate)
    def test_changed_deployment_stops_before_any_secret_staging(self):
        with patch.object(a.d,'deployment_state',return_value=[('changed',100)]),patch.object(a.subprocess,'run') as run:
            with self.assertRaises(a.d.Stop):a.deploy('fake',self.records())
            run.assert_not_called()
    def test_noninteractive_never_reads_token_or_mutates(self):
        with patch.object(a.sys.stdin,'isatty',return_value=False),patch.object(a.getpass,'getpass') as prompt,patch.object(a,'deploy') as deploy:
            with self.assertRaises(a.d.Stop):a.main()
            prompt.assert_not_called();deploy.assert_not_called()

if __name__=='__main__':unittest.main()
