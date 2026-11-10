#!/usr/bin/env python3
"""Deploy only a reviewed, DISABLED two-Worker packet. Never opens Terminal or creates credentials.
No secrets in argv/files/logs. Invoke only after action-time approval and packet review.
"""
import argparse, getpass, hashlib, json, os, pathlib, re, resource, shutil, subprocess, sys, tempfile
ACCOUNT='994f7b36c1e049ae197d27009177804f'
NAMES=('feast-proxy-production','feast-owner-validation')
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def inspect(packet):
    packet=pathlib.Path(packet).resolve(); m=json.loads((packet/'manifest.json').read_text())
    if m.get('account')!=ACCOUNT or m.get('workerNames')!=list(NAMES): raise ValueError('wrong packet scope')
    files=m.get('files',{})
    if set(files)!={'production/worker.js','production/wrangler.json','owner/worker.js','owner/wrangler.json'}: raise ValueError('unexpected packet files')
    for name,value in files.items():
        path=packet/name
        if path.is_symlink() or not path.is_file() or sha(path)!=value: raise ValueError('packet hash mismatch')
    for folder,name in zip(('production','owner'),NAMES):
        c=json.loads((packet/folder/'wrangler.json').read_text())
        if c.get('name')!=name or c.get('account_id')!=ACCOUNT or c.get('main')!='worker.js' or c.get('observability')!={'enabled':False} or c.get('send_metrics') is not False: raise ValueError('unsafe configuration')
        if c.get('vars',{}).get('ENABLED')!='false': raise ValueError('activation forbidden')
        common={'name','main','account_id','compatibility_date','workers_dev','preview_urls','observability','send_metrics','vars'}
        if c.get('workers_dev') is not True or c.get('preview_urls') is not False or c.get('compatibility_date')!='2026-10-20': raise ValueError('unexpected network configuration')
        if folder=='production':
            if set(c)!=common|{'durable_objects','migrations'} or c['vars']!={'ENVIRONMENT':'production','ENABLED':'false','LIVE_AI':'false','OWNER_VALIDATION_ENABLED':'false',**{k:'false' for k in ['ALLOW_PUBLIC_LOOKUP','ALLOW_RECONCILED_BUDGET','ALLOW_LEGACY_RECONCILIATION','ASK_FEAST_RECOVERY_ENABLED'] if k in c['vars']}}: raise ValueError('dispatch forbidden')
            # Two explicit reviewed schemas: the historical ledger-only packet,
            # or the additive AnswerJobs scaffold with recovery still OFF. A
            # partial migration/binding/flag combination is never accepted.
            bindings=[{'name':'PRODUCTION_STATE','class_name':'ProductionLedger'}]
            migrations=[{'tag':'production-v1','new_sqlite_classes':['ProductionLedger']}]
            if 'ASK_FEAST_RECOVERY_ENABLED' in c['vars']:
                bindings.append({'name':'ANSWER_JOBS','class_name':'AnswerJobs'})
                migrations.append({'tag':'answer-jobs-v1','new_sqlite_classes':['AnswerJobs']})
            if c['durable_objects']!={'bindings':bindings} or c['migrations']!=migrations: raise ValueError('unexpected storage change')
        else:
            if set(c)!=common|{'services'} or c['vars']!={'ENABLED':'false','LIVE_AI':'false',**{k:'false' for k in ['ALLOW_PUBLIC_LOOKUP','ALLOW_RECONCILED_BUDGET'] if k in c['vars']}} or c['services']!=[{'binding':'PRODUCTION','service':'feast-proxy-production','entrypoint':'OwnerValidationRPC'}]: raise ValueError('unexpected owner binding')
    cli=pathlib.Path(m['wranglerCLI']).resolve(); package=cli.parent.parent/'package.json'
    if json.loads(package.read_text()).get('version')!='4.151.3' or sha(cli)!=m.get('wranglerSHA256'): raise ValueError('pinned Wrangler changed')
    return packet,m,cli

def deploy(packet,m,cli,token,run=subprocess.run):
    # A private, no-content log sink prevents Wrangler's debug log from persisting request headers.
    receipt={'state':'starting','versions':{},'providerCalls':0,'activation':False}
    receipt_path=packet/'deployment-receipt.json'
    if receipt_path.exists(): return False  # One-shot: inspect remote outcome before any reviewed rerun.
    def save(): receipt_path.write_text(json.dumps(receipt,indent=2)+'\n')
    with tempfile.TemporaryDirectory(prefix='feast-deploy-log-sink-') as directory:
        sink=pathlib.Path(directory)/'discard.log';sink.symlink_to('/dev/null')
        env={k:v for k,v in os.environ.items() if not any(word in k.upper() for word in ('TOKEN','SECRET','API_KEY'))}
        env.update({'CLOUDFLARE_API_TOKEN':token,'CLOUDFLARE_ACCOUNT_ID':ACCOUNT,'WRANGLER_LOG_PATH':str(sink),'WRANGLER_LOG_SANITIZE':'true','WRANGLER_SEND_METRICS':'false','CI':'true','NO_COLOR':'1'})
        node=shutil.which('node')
        if not node: raise ValueError('Node unavailable')
        try:
            for folder,name in zip(('production','owner'),NAMES):
                # Recheck immutable review inputs immediately before each mutation.
                inspect(packet)
                receipt['state']='deploying-'+name;save()
                result=run([node,str(cli),'deploy','--no-bundle','--config',str(packet/folder/'wrangler.json')],cwd=packet/folder,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=180)
                # Do not print or persist raw CLI output, even on failure.
                match=re.search(r'Current Version ID:\s*([a-f0-9-]{36})',result.stdout)
                if result.returncode!=0 or not match:
                    receipt['state']='uncertain-'+name;save();return False
                receipt['versions'][name]=match.group(1);receipt['state']='verified-cli-completion-'+name;save()
            receipt['state']='deployed-disabled-needs-health-verification';save();return True
        except (subprocess.TimeoutExpired,KeyboardInterrupt,Exception):
            receipt['state']='uncertain-stop-no-retry';save();return False
        finally:
            env.pop('CLOUDFLARE_API_TOKEN',None)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('packet');parser.add_argument('--deploy-reviewed',action='store_true');args=parser.parse_args()
    try: packet,m,cli=inspect(args.packet)
    except Exception: print('STOP: packet or pinned tool validation failed. No deployment attempted.');return 1
    if not args.deploy_reviewed:
        print('Reviewed disabled packet verified locally. No token requested or network action performed.');return 0
    if not sys.stdin.isatty(): print('STOP: hidden entry requires an interactive Terminal.');return 1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    token=''
    try:
        token=getpass.getpass('Approved temporary Cloudflare setup token (hidden): ')
        if not re.fullmatch(r'[A-Za-z0-9_-]{20,200}',token): print('STOP: invalid token format.');return 1
        ok=deploy(packet,m,cli,token)
        print('Disabled deployment completed; health verification still required.' if ok else 'STOP: deployment outcome uncertain. Inspect receipt and remote versions before any retry.')
        return 0 if ok else 1
    except KeyboardInterrupt: print('Cancelled. No automatic retry.');return 1
    finally: token=''
if __name__=='__main__': sys.exit(main())
