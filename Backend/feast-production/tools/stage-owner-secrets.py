#!/usr/bin/env python3
"""Secure, one-shot fallback: stage secrets in INACTIVE versions; never deploy/activate/call OpenAI."""
import argparse,copy,datetime,getpass,importlib.util,json,os,pathlib,re,resource,shutil,subprocess,sys,tempfile
spec=importlib.util.spec_from_file_location('reviewed',pathlib.Path(__file__).with_name('deploy-reviewed.py'));reviewed=importlib.util.module_from_spec(spec);spec.loader.exec_module(reviewed)
def owner_record(data,now=None):
    now=now or datetime.datetime.now(datetime.timezone.utc)
    if not isinstance(data,list) or len(data)!=1 or not isinstance(data[0],dict): raise ValueError('owner record shape')
    r=data[0]
    if set(r)!={'id','sha256','createdAt','expiresAt'} or r['id']!='owner-original-iphone17' or not re.fullmatch('[a-f0-9]{64}',r.get('sha256','')): raise ValueError('owner record fields')
    created=datetime.datetime.fromisoformat(r['createdAt'].replace('Z','+00:00'));expires=datetime.datetime.fromisoformat(r['expiresAt'].replace('Z','+00:00'))
    if created.tzinfo is None or expires.tzinfo is None or created>now or expires<=now or not datetime.timedelta(0)<expires-created<=datetime.timedelta(hours=48): raise ValueError('owner record expiry')
    return json.dumps(data,separators=(',',':'),sort_keys=True)
def latest(items):
    if not isinstance(items,list) or not items: raise ValueError('missing versions')
    return max(items,key=lambda v:v['metadata']['created_on'])['id']
def active(items):
    d=max(items,key=lambda v:v['created_on'])
    if len(d['versions'])!=1 or d['versions'][0]['percentage']!=100: raise ValueError('split deployment')
    return d['versions'][0]['version_id']
def metadata_matches(before,after,secret):
    a=copy.deepcopy(before['resources']);b=copy.deepcopy(after['resources'])
    bindings_a=a.pop('bindings');bindings_b=b.pop('bindings')
    if any(x['name']==secret for x in bindings_a): raise ValueError('refuse secret replacement')
    added=[x for x in bindings_b if x['name']==secret]
    if len(added)!=1 or added[0]['type']!='secret_text' or set(added[0])!={'type','name'}: raise ValueError('secret metadata invalid')
    normalize=lambda x:sorted(x,key=lambda v:v['name'])
    if a!=b or normalize(bindings_a)!=normalize([x for x in bindings_b if x['name']!=secret]): raise ValueError('unrelated resource drift')
def stage(packet,cli,cloudflare_token,openai_key,record,run=subprocess.run):
    receipt_path=packet/'secret-staging-receipt.json'
    if receipt_path.exists(): return False
    deployed=json.loads((packet/'deployment-receipt.json').read_text())
    if deployed.get('state')!='deployed-disabled-needs-health-verification' or set(deployed.get('versions',{}))!=set(reviewed.NAMES): return False
    receipt={'state':'preflight','stagedVersions':{},'activation':False,'providerCalls':0}
    save=lambda:receipt_path.write_text(json.dumps(receipt,indent=2)+'\n')
    with tempfile.TemporaryDirectory(prefix='feast-secret-log-sink-') as directory:
        sink=pathlib.Path(directory)/'discard.log';sink.symlink_to('/dev/null')
        env={k:v for k,v in os.environ.items() if not any(w in k.upper() for w in ('TOKEN','SECRET','API_KEY'))}
        env.update({'CLOUDFLARE_API_TOKEN':cloudflare_token,'CLOUDFLARE_ACCOUNT_ID':reviewed.ACCOUNT,'WRANGLER_LOG_PATH':str(sink),'WRANGLER_LOG_SANITIZE':'true','WRANGLER_SEND_METRICS':'false','CI':'true','NO_COLOR':'1'})
        def command(folder,args,value=None):
            node=shutil.which('node')
            if not node: raise ValueError('Node unavailable')
            options={'input':value} if value is not None else {'stdin':subprocess.DEVNULL}
            result=run([node,str(cli),*args,'--config',str(packet/folder/'wrangler.json')],cwd=packet/folder,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=120,**options)
            if result.returncode!=0: raise ValueError('CLI result unverified')
            return result.stdout
        def read(folder,args): return json.loads(command(folder,args))
        try:
            before={}
            # Check BOTH targets before the first secret write. No draft Worker fallback.
            for folder,name in zip(('production','owner'),reviewed.NAMES):
                expected=deployed['versions'][name]
                if active(read(folder,['deployments','list','--json']))!=expected or latest(read(folder,['versions','list','--json']))!=expected: raise ValueError('remote version drift')
                v=read(folder,['versions','view',expected,'--json']);bindings=v['resources']['bindings']
                variables={x['name']:x.get('text') for x in bindings if x['type']=='plain_text'}
                config=json.loads((packet/folder/'wrangler.json').read_text())
                if variables!=config['vars']: raise ValueError('flags not reviewed OFF state')
                before[folder]=v
            save()
            for folder,name,secret,value in [('production',reviewed.NAMES[0],'OPENAI_API_KEY',openai_key),('owner',reviewed.NAMES[1],'OWNER_TOKEN_HASHES_JSON',record)]:
                reviewed.inspect(packet)
                expected=deployed['versions'][name]
                if active(read(folder,['deployments','list','--json']))!=expected or latest(read(folder,['versions','list','--json']))!=expected: raise ValueError('remote drift before staging')
                if any(b['name']==secret for b in before[folder]['resources']['bindings']): raise ValueError('secret already exists')
                receipt['state']='staging-'+secret;save()
                output=command(folder,['versions','secret','put',secret],value)
                match=re.search(r'Created version ([a-f0-9-]{36}) with secret',output)
                if not match: raise ValueError('secret outcome uncertain')
                version=match.group(1);view=read(folder,['versions','view',version,'--json'])
                metadata_matches(before[folder],view,secret)
                if active(read(folder,['deployments','list','--json']))!=deployed['versions'][name]: raise ValueError('active version changed')
                receipt['stagedVersions'][name]=version;receipt['state']='verified-inactive-'+secret;save()
            receipt['state']='secrets-staged-inactive-needs-browser-review';save();return True
        except (Exception,KeyboardInterrupt):
            receipt['state']='uncertain-stop-inspect-versions-no-retry';save();return False
        finally:env.pop('CLOUDFLARE_API_TOKEN',None)
def main():
    parser=argparse.ArgumentParser();parser.add_argument('packet');parser.add_argument('owner_metadata');parser.add_argument('--stage-reviewed-secrets',action='store_true');args=parser.parse_args()
    try:
        packet,manifest,cli=reviewed.inspect(args.packet)
        record=owner_record(json.loads(pathlib.Path(args.owner_metadata).read_text()))
    except Exception: print('STOP: packet or hash-only owner metadata validation failed. No request made.');return 1
    if not args.stage_reviewed_secrets: print('Local packet/owner metadata valid. No prompt, network or credential operation.');return 0
    if not sys.stdin.isatty(): print('STOP: interactive hidden input required.');return 1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));cf='';key=''
    try:
        cf=getpass.getpass('Approved temporary Cloudflare setup token (hidden): ')
        key=getpass.getpass('New Feast production OpenAI key (hidden): ')
        if not re.fullmatch('[A-Za-z0-9_-]{20,200}',cf) or not re.fullmatch('sk-[A-Za-z0-9_-]{20,500}',key): print('STOP: invalid credential format.');return 1
        ok=stage(packet,cli,cf,key,record)
        print('Both secrets verified in inactive versions. No activation or model request.' if ok else 'STOP: inspect safe receipt/remote versions before retry. No automatic repeat.')
        return 0 if ok else 1
    except KeyboardInterrupt: print('Cancelled. No automatic retry.');return 1
    finally:cf='';key=''
if __name__=='__main__':sys.exit(main())
