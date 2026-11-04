#!/usr/bin/env python3
"""Offline builder only. Never authenticates, deploys, provisions credentials or launches an app."""
import hashlib,json,os,pathlib,subprocess,sys,plistlib
backend=pathlib.Path(__file__).resolve().parents[2]
cli=backend/'feast-proxy/node_modules/wrangler/wrangler-dist/cli.js'
packet=pathlib.Path(sys.argv[1]).resolve();packet.mkdir(mode=0o700)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
manifest={'account':'994f7b36c1e049ae197d27009177804f','workerNames':['feast-proxy-production','feast-owner-validation'],'wranglerCLI':str(cli),'wranglerSHA256':sha(cli),'files':{}}
env={k:v for k,v in os.environ.items() if not any(w in k.upper() for w in ('TOKEN','SECRET','API_KEY'))};env.update({'WRANGLER_SEND_METRICS':'false','CI':'true','WRANGLER_LOG_PATH':'/tmp/feast-owner-packet-build.log'})
for folder,source in [('production','feast-production'),('owner','feast-owner-validation')]:
 output=packet/folder;output.mkdir();config=backend/source/'wrangler.jsonc'
 subprocess.run(['node',str(cli),'deploy','--dry-run','--config',str(config),'--outdir',str(output)],env=env,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 worker=output/'worker.js';worker.write_text(worker.read_text().replace('//# sourceMappingURL=worker.js.map',''))
 for name in ('worker.js.map','README.md'):
  p=output/name
  if p.exists():p.unlink()
 c=json.loads(config.read_text());c['main']='worker.js';(output/'wrangler.json').write_text(json.dumps(c,indent=2)+'\n')
 for name in ('worker.js','wrangler.json'):manifest['files'][folder+'/'+name]=sha(output/name)
(packet/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
info=plistlib.loads((backend.parent/'Feast/Info.plist').read_bytes());info.update({'FeastAskOwnerValidationEnabled':True,'FeastAskOwnerValidationEndpoint':'https://feast-owner-validation.jonmgalante.workers.dev/v1/answer'})
(packet/'OwnerValidation-Info.plist').write_bytes(plistlib.dumps(info))
print('Offline disabled packet built:',packet)
