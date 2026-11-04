#!/usr/bin/env python3
"""One hidden setup-token entry; existing native credential; public pixels only."""
import getpass
import json
import os
from pathlib import Path
import tempfile
import time
import sys
import activate_saved as a
import deploy_dev as d

BASELINE = '4ff7f5cb-0399-405b-b866-8b739bdb2f1a'
STATUS = d.ROOT / '.feast-screenshot-status.json'


def deploy(token, baseline, mode):
    active = [(baseline, 100)]
    if d.deployment_state(token) != active or d.latest_id(token) != baseline:
        raise d.Stop('Dev version changed. Inspect metadata; no automatic deployment retry.')
    before = d.fetch_json(d.BASE+'/versions/'+baseline, token)
    bindings = before.get('resources', {}).get('bindings', [])
    budget = [x for x in bindings if x.get('name') == 'BUDGET']
    if len(budget) != 1 or not all(d.secret_exists(before, name) for name in ('OPENAI_API_KEY','CLIENT_TOKEN_HASHES_JSON')):
        raise d.Stop('Existing encrypted bindings or persistent BUDGET not verified.')
    config = json.loads((d.ROOT/'wrangler.jsonc').read_text())
    config['env']['dev']['unsafe']['bindings'].append({'name':'CLIENT_TOKEN_HASHES_JSON','type':'inherit'})
    config['env']['dev']['vars'].update(ALLOW_SAVED_METADATA='true', ALLOW_SELECTED_SCREENSHOT=mode)
    fd, path = tempfile.mkstemp(prefix='.feast-screenshot-', suffix='.json', dir=str(d.ROOT))
    try:
        with os.fdopen(fd,'w') as out: json.dump(config,out)
        version = d.run_deploy(token, active, expected_latest=baseline, config_path=path, live=True)
    finally:
        Path(path).unlink(missing_ok=True)
    after = d.fetch_json(d.BASE+'/versions/'+version, token)
    if [x for x in after.get('resources',{}).get('bindings',[]) if x.get('name')=='BUDGET'] != budget:
        raise d.Stop('BUDGET binding differs after deployment; stop without requests.')
    return version


def valid_image_result(result, previous_budget):
    if not isinstance(result,dict): return False
    budget=result.get('budget',{})
    return (result.get('httpStatus')==200 and result.get('accepted') is True and
            result.get('model')=='gpt-6-luna' and result.get('candidateCount')==0 and
            result.get('extractionVerified') is True and result.get('noCollectionCandidates') is True and
            previous_budget['reservedMicroUSD']+50000 <= budget.get('reservedMicroUSD',-1) <= 5000000 and
            previous_budget['userReservedMicroUSD']+50000 <= budget.get('userReservedMicroUSD',-1) <= 2500000)


def verify_public_image(path):
    data=path.read_bytes()
    if len(data)>196608 or data[:2]!=b'\xff\xd8':raise d.Stop('Prepared test image type/size invalid.')
    offset=2; dimensions=None
    while offset+4<=len(data):
        if data[offset]!=255:raise d.Stop('Prepared test JPEG structure invalid.')
        marker=data[offset+1]
        if marker==218:break
        length=int.from_bytes(data[offset+2:offset+4],'big')
        if length<2 or offset+2+length>len(data):raise d.Stop('Prepared test JPEG segment invalid.')
        if 225<=marker<=239 or marker==254:raise d.Stop('Prepared test image retains metadata.')
        if marker in (192,193,194):
            dimensions=(int.from_bytes(data[offset+7:offset+9],'big'),int.from_bytes(data[offset+5:offset+7],'big'))
        offset+=2+length
    if not dimensions or not all(0<x<=1024 for x in dimensions):raise d.Stop('Prepared test image dimensions invalid.')
    return {'bytes':len(data),'width':dimensions[0],'height':dimensions[1],'metadataStripped':True,'mime':'image/jpeg'}


def main():
    d.verify_configuration()
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        raise d.Stop('Use the hidden local Terminal prompt only.')
    container = Path(a.sim('get_app_container',a.SIMULATOR,a.BUNDLE,'data'))
    before = a.counts(container)
    previous = json.loads(a.STATUS.read_text())
    if before != previous['countsAfter'] or previous.get('verified') is not True:
        raise d.Stop('Collection differs from verified 33-place/5-city baseline.')
    previous_budget=json.loads((container/'Documents/FeastSavedMetadataReceipt.json').read_text())['budget']
    STATUS.write_text(json.dumps({'phase':'awaiting-token','verified':False}))
    token = getpass.getpass('Existing Cloudflare dev-only token (hidden): ')
    if not token or token.startswith('sk-') or any(x.isspace() for x in token):
        raise d.Stop('Invalid setup token. No action.')
    try:
        # Public capability remains off until the native public-image result passes.
        version = deploy(token, BASELINE, 'verification')
        STATUS.write_text(json.dumps({'phase':'verification-deployed','version':version,'verified':False}))
        receipt = container/'Documents/FeastScreenshotReceipt.json'
        a.sim('terminate',a.SIMULATOR,a.BUNDLE,required=False)
        started = time.time()
        a.sim('launch',a.SIMULATOR,a.BUNDLE,'-feastHostedSavedPlaces','-feastScreenshotSmokeTest')
        result = None
        for _ in range(75):
            if receipt.is_file() and receipt.stat().st_mtime >= started:
                result = json.loads(receipt.read_text())
                if result.get('httpStatus') != 200 or result.get('accepted') is True: break
            time.sleep(1)
        if not valid_image_result(result,previous_budget):
            # No repeat model request. Disable the verification gate after a known failure.
            if result and result.get('httpStatus') is not None:
                disabled = deploy(token,version,'false')
                STATUS.write_text(json.dumps({'phase':'disabled-after-failed-check','version':disabled,'verified':False,'response':result}))
                a.sim('terminate',a.SIMULATOR,a.BUNDLE,required=False)
                a.sim('launch',a.SIMULATOR,a.BUNDLE,'-feastHostedSavedPlaces')
            raise d.Stop('Public screenshot not verified; feature stays hidden. Reason: '+str((result or {}).get('reason','native verification incomplete')))
        budget = result.get('budget',{})
        image=verify_public_image(container/'Documents/FeastPublicScreenshot.jpg')
        if a.counts(container) != before:
            raise d.Stop('Collection count/UUID verification failed; no restoration or reset.')
        a.sim('io',a.SIMULATOR,'screenshot','/tmp/feast-public-image-answer.png')
        enabled = deploy(token,version,'true')
        status, health = d.fetch_json(d.ENDPOINT+'/health')
        if status != 200 or health.get('selectedScreenshotEnabled') is not True:
            raise d.Stop('Activation health uncertain; inspect before retrying.')
        STATUS.write_text(json.dumps({'phase':'enabled','version':enabled,'verificationVersion':version,'verified':True,'countsBefore':before,'countsAfter':a.counts(container),'response':result,'image':image}))
        # Exit the empty-catalog QA launch and restore the actual collection/picker.
        a.sim('terminate',a.SIMULATOR,a.BUNDLE,required=False)
        a.sim('launch',a.SIMULATOR,a.BUNDLE,'-feastHostedSavedPlaces')
        print('SCREENSHOT VERIFIED AND ENABLED. Generic restaurant name, cuisine, dish and hours extracted; no collection metadata sent.')
        print('Shared lifetime allowance remaining: $%.2f.' % ((5000000-budget['reservedMicroUSD'])/1000000))
        print('No credentials rotated. Existing expiry, tester-two and persistent BUDGET retained.')
    finally:
        token = None

if __name__ == '__main__':
    try: main()
    except (d.Stop,KeyboardInterrupt) as error:
        print('STOP:',str(error) or 'Cancelled.',file=sys.stderr)
        sys.exit(1)
