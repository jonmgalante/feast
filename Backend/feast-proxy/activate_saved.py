#!/usr/bin/env python3
"""Prepared exact tester-one replacement + dev metadata activation. Run only after approval."""
import getpass
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import deploy_dev as d

SIMULATOR = '4F6EAF55-E0E2-4895-9D19-C2D1D4D89D8D'
QA_SIMULATOR = '5325CDB2-9206-4CA4-B433-17DC93BC5A6B'
BUNDLE = 'com.jongalante.Feast'
BASELINE = '5cf43467-1887-407a-b095-d3bfe85d707a'
EXPIRY = '2026-11-22T14:30:00Z'
STATUS = d.ROOT / '.feast-saved-status.json'


def sim(*args, required=True):
    result = subprocess.run(['xcrun','simctl',*args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if required and result.returncode:
        raise d.Stop('Simulator operation failed: '+args[0]+'. No automatic retry.')
    return result.stdout.decode('utf8','replace').strip()


def combine_replacement(previous, replacement):
    if not isinstance(previous,list) or len(previous) != 2:
        raise d.Stop('Expected the existing two-user hash records.')
    users = {record['id']:record for record in previous}
    if set(users) != {'feast-dev-tester-one','feast-dev-tester-two'}:
        raise d.Stop('Existing tester identities differ. No credential changes.')
    if (not isinstance(replacement,dict) or set(replacement) != {'id','sha256','expiresAt'} or
        replacement['id'] != 'feast-dev-tester-one' or replacement['expiresAt'] != EXPIRY or
        not isinstance(replacement['sha256'],str) or d.re.fullmatch('[a-f0-9]{64}',replacement['sha256']) is None or
        replacement['sha256'] in {users['feast-dev-tester-one']['sha256'],users['feast-dev-tester-two']['sha256']}):
        raise d.Stop('Replacement hash differs from the approved tester-one specification.')
    if any(record['expiresAt'] != EXPIRY for record in previous):
        raise d.Stop('Original credential expiry changed; no expansion allowed.')
    return [replacement,users['feast-dev-tester-two']]


def counts(container):
    result = []
    for name in ('Feast.sqlite','Feast-Shared.sqlite'):
        paths = list(container.rglob(name))
        if len(paths) != 1:
            raise d.Stop('Expected existing private/shared stores. No store creation or copying allowed.')
        with sqlite3.connect(paths[0].as_uri()+'?mode=ro',uri=True) as connection:
            connection.execute('PRAGMA query_only=ON')
            result.append({'store':name,'places':connection.execute('SELECT count(*) FROM ZSAVEDPLACE').fetchone()[0],
                           'cities':connection.execute('SELECT count(*) FROM ZFEASTLIST').fetchone()[0],
                           'placeIDsDigest':hashlib.sha256('|'.join(sorted(value[0].hex() if value[0] is not None else 'nil' for value in connection.execute('SELECT ZID FROM ZSAVEDPLACE'))).encode()).hexdigest(),
                           'cityIDsDigest':hashlib.sha256('|'.join(sorted(value[0].hex() if value[0] is not None else 'nil' for value in connection.execute('SELECT ZID FROM ZFEASTLIST'))).encode()).hexdigest()})
    return result


def deploy(token, users):
    active = d.deployment_state(token)
    if active != [(BASELINE,100)] or d.latest_id(token) != BASELINE:
        raise d.Stop('Dev deployment changed from reviewed baseline. Read metadata before retrying.')
    version = d.fetch_json(d.BASE+'/versions/'+BASELINE,token)
    if not all(d.secret_exists(version,name) for name in ('OPENAI_API_KEY','CLIENT_TOKEN_HASHES_JSON')):
        raise d.Stop('Required encrypted bindings not verified. No secret changes.')
    env={k:v for k,v in os.environ.items() if not k.startswith(('CLOUDFLARE_','OPENAI_','WRANGLER_'))}
    env.update(CLOUDFLARE_ACCOUNT_ID=d.ACCOUNT,CLOUDFLARE_API_TOKEN=token,CI='true',WRANGLER_SEND_METRICS='false',WRANGLER_LOG='error',WRANGLER_LOG_PATH='/dev/null')
    try:
        uploaded=subprocess.run([str(d.ROOT/'node_modules/.bin/wrangler'),'versions','secret','put','CLIENT_TOKEN_HASHES_JSON','--env','dev'],
            cwd=str(d.ROOT),env=env,input=json.dumps(users).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=180)
    except subprocess.TimeoutExpired:
        raise d.Stop('Hash staging timed out; outcome uncertain. Inspect versions before any retry.') from None
    finally:
        env.pop('CLOUDFLARE_API_TOKEN',None)
    staged=d.latest_id(token)
    metadata=d.fetch_json(d.BASE+'/versions/'+staged,token)
    if uploaded.returncode or staged==BASELINE or d.deployment_state(token)!=active or not all(d.secret_exists(metadata,name) for name in ('OPENAI_API_KEY','CLIENT_TOKEN_HASHES_JSON')):
        raise d.Stop('Replacement staging not verified. No repeat mutation or budget reset.')
    config=json.loads((d.ROOT/'wrangler.jsonc').read_text())
    config['env']['dev']['unsafe']['bindings'].append({'name':'CLIENT_TOKEN_HASHES_JSON','type':'inherit'})
    config['env']['dev']['vars'].update(ALLOW_SAVED_METADATA='true',ALLOW_SELECTED_SCREENSHOT='false')
    fd,path=tempfile.mkstemp(prefix='.feast-saved-',suffix='.json',dir=str(d.ROOT))
    try:
        with os.fdopen(fd,'w') as output:json.dump(config,output)
        return d.run_deploy(token,active,expected_latest=staged,config_path=path,live=True)
    finally:
        Path(path).unlink(missing_ok=True)


def verify_real(version,container,before):
    receipt=container/'Documents/FeastSavedMetadataReceipt.json'
    sim('terminate',SIMULATOR,BUNDLE,required=False)
    started=time.time()
    sim('launch',SIMULATOR,BUNDLE,'-feastHostedSavedPlaces','-feastSavedMetadataSmokeTest')
    try:
        for _ in range(60):
            if receipt.is_file() and receipt.stat().st_mtime>=started:
                result=json.loads(receipt.read_text())
                if result.get('httpStatus') != 200:
                    raise d.Stop('Saved-place request failed: HTTP %s / %s. No automatic second request.' % (result.get('httpStatus'),result.get('reason',result.get('error','unknown'))))
                if result.get('accepted') is True:
                    budget=result.get('budget',{})
                    if result.get('model')!='gpt-6-luna' or not 150000 <= budget.get('reservedMicroUSD',-1) <= 5000000:
                        raise d.Stop('Model or preserved budget verification incomplete.')
                    STATUS.write_text(json.dumps({'version':version,'verified':True,'countsBefore':before,'countsAfter':counts(container),'response':result}))
                    print('REAL SAVED-PLACE ANSWER VERIFIED. No question, place names, addresses, notes, images or answer text logged.')
                    print('Shared allowance remaining: $%.2f.' % ((5000000-budget['reservedMicroUSD'])/1000000))
                    return
            time.sleep(1)
        raise d.Stop('Native response not verified within 60 seconds; no automatic repeat request.')
    finally:
        after=counts(container)
        if after!=before:
            raise d.Stop('Store counts changed. Stop for investigation; do not restore, erase or reseed automatically.')


def main():
    d.verify_configuration()
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        raise d.Stop('Use the masked local Terminal prompt; never pass a credential in arguments or chat.')
    container=Path(sim('get_app_container',SIMULATOR,BUNDLE,'data'))
    qa=Path(sim('get_app_container',QA_SIMULATOR,BUNDLE,'data'))
    before=counts(container)
    if [(row['store'],row['places'],row['cities']) for row in before] != [('Feast.sqlite',33,5),('Feast-Shared.sqlite',0,0)]:
        raise d.Stop('Selected collection differs from approved 33-place/5-city baseline. No mutation or query.')
    previous=json.loads(d.client_hashes(qa/'Documents/FeastSyntheticClientHashes.json'))
    replacement_file=container/'Documents/FeastTesterOneReplacementHash.json'
    token=getpass.getpass('Existing Cloudflare dev-only token (hidden): ')
    if not token or token.startswith('sk-') or any(c.isspace() for c in token):raise d.Stop('Invalid token; no request sent.')
    try:
        # Authenticate/read current state before making the approved native credential change.
        if d.deployment_state(token) != [(BASELINE,100)] or d.latest_id(token) != BASELINE:
            raise d.Stop('Dev baseline changed. No credential generation or deployment.')
        original=d.fetch_json(d.BASE+'/versions/'+BASELINE,token)
        if not all(d.secret_exists(original,name) for name in ('OPENAI_API_KEY','CLIENT_TOKEN_HASHES_JSON')):
            raise d.Stop('Required encrypted bindings not verified. No credential generation.')
        print('Existing dev deployment verified. Preparing approved tester-one replacement in iPhone 17 Keychain.',flush=True)
        sim('terminate',SIMULATOR,BUNDLE,required=False)
        sim('launch',SIMULATOR,BUNDLE,'-feastHostedSavedPlaces','-feastReplaceTesterOne')
        for _ in range(20):
            if replacement_file.is_file() and replacement_file.stat().st_size<=1024:
                break
            time.sleep(1)
        else:
            raise d.Stop('Native Keychain replacement not established; no server secret change. Inspect native setup before retrying.')
        users=combine_replacement(previous,json.loads(replacement_file.read_text()))
        if counts(container)!=before:
            raise d.Stop('Collection changed during native preparation. No deployment or real query.')
        version=deploy(token,users)
        STATUS.write_text(json.dumps({'version':version,'verified':False,'phase':'deployed','countsBefore':before}))
        verify_real(version,container,before)
    finally:
        token=None


if __name__=='__main__':
    try:main()
    except (d.Stop,KeyboardInterrupt) as error:
        try: status=json.loads(STATUS.read_text()) if STATUS.is_file() else {}
        except (ValueError,OSError): status={}
        status.update({'verified':False,'error':str(error) or 'Cancelled.'})
        STATUS.write_text(json.dumps(status))
        print('STOP:',str(error) or 'Cancelled.',file=sys.stderr)
        sys.exit(1)
