#!/usr/bin/env python3
"""Offline build/sign only: no Keychain, network, credentials, prompt or app launch."""
import hashlib,json,pathlib,subprocess
repo=pathlib.Path(__file__).resolve().parents[3];tools=pathlib.Path(__file__).parent
review=pathlib.Path('/tmp/feast-deployment-access-reviewed');review.mkdir(exist_ok=True,mode=0o700)
output=repo/'.local-tools/FeastDeploymentAccess';output.parent.mkdir(exist_ok=True,mode=0o700)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
paths=['Backend/feast-production/tools/renew-owner-access.py','Backend/feast-production/tools/update-production-code.py','Backend/feast-production/tools/update-existing.py','Backend/feast-production/tools/deploy-reviewed.py']
pins={p:sha(repo/p) for p in paths};literal='['+', '.join(json.dumps(k)+': '+json.dumps(v) for k,v in pins.items())+']'
source=review/'FeastDeploymentAccess.swift';source.write_text((tools/'FeastDeploymentAccess.swift.in').read_text().replace('@@REVIEWED_PINS@@',literal))
subprocess.run(['xcrun','swiftc','-module-cache-path',str(review/'cache'),str(source),'-o',str(output)],check=True)
subprocess.run(['codesign','--force','--sign','-','--identifier','com.jongalante.Feast.DeploymentAccess',str(output)],check=True)
subprocess.run(['codesign','--verify','--strict',str(output)],check=True)
(review/'manifest.json').write_text(json.dumps({'sourceSHA256':sha(source),'binarySHA256':sha(output),'binary':str(output),'pins':pins},indent=2)+'\n')
print('Offline deployment-access bridge built and signed. No credential access.')
