#!/usr/bin/env python3
"""Repair dev answer contract, then three approved metadata-only native checks."""
import getpass
import json
from pathlib import Path
import sys
import time
import activate_saved as a
import activate_screenshots as image
import deploy_dev as d
STATUS=d.ROOT/'.feast-answer-repair-status.json'
BASELINE='921e9e5a-8dbf-48d9-aeea-41e1f77b33eb'

def main():
    d.verify_configuration()
    if not sys.stdin.isatty() or not sys.stderr.isatty():raise d.Stop('Use hidden Terminal prompt only.')
    c=Path(a.sim('get_app_container',a.SIMULATOR,a.BUNDLE,'data'))
    before=a.counts(c)
    baseline=json.loads(a.STATUS.read_text())
    if before!=baseline['countsAfter']:raise d.Stop('Collection count/UUID baseline changed; no action.')
    STATUS.write_text(json.dumps({'phase':'awaiting-token','verified':False}))
    token=getpass.getpass('Existing Cloudflare dev-only token (hidden): ')
    if not token or token.startswith('sk-') or any(x.isspace() for x in token):raise d.Stop('Invalid setup token.')
    try:
        version=image.deploy(token,BASELINE,'false')
        state={'version':version,'verified':False,'checks':[],'countsBefore':before}
        STATUS.write_text(json.dumps(state))
        last=baseline['response']['budget']['reservedMicroUSD']
        for check in ('memory','cuisine','missing'):
            a.sim('terminate',a.SIMULATOR,a.BUNDLE,required=False)
            started=time.time()
            a.sim('launch',a.SIMULATOR,a.BUNDLE,'-feastHostedSavedPlaces','-feastTextCheck='+check)
            receipt=c/'Documents/FeastSavedMetadataReceipt.json'
            result=None
            for _ in range(65):
                if receipt.is_file() and receipt.stat().st_mtime>=started:
                    result=json.loads(receipt.read_text())
                    if result.get('httpStatus')!=200 or result.get('accepted') is True:break
                time.sleep(1)
            state['checks'].append({'case':check,'response':result})
            state['countsAfter']=a.counts(c)
            STATUS.write_text(json.dumps(state))
            if not result or result.get('accepted') is not True:
                raise d.Stop('Native '+check+' answer not verified: '+str((result or {}).get('reason','incomplete'))+'. No automatic repeat.')
            current=result.get('budget',{}).get('reservedMicroUSD',-1)
            if not last+50000<=current<=5000000:raise d.Stop('Budget preservation check incomplete.')
            last=current
            if a.counts(c)!=before:raise d.Stop('Collection changed. No restore/reset/reseed.')
            a.sim('io',a.SIMULATOR,'screenshot','/tmp/feast-answer-'+check+'.png')
            print('Verified '+check+' question: HTTP 200 and client-accepted bounded answer.',flush=True)
        state['verified']=True
        STATUS.write_text(json.dumps(state))
        print('ALL THREE TEXT CHECKS PASSED. Screenshots still disabled. Shared remaining: $%.2f.' % ((5000000-last)/1000000),flush=True)
    finally:token=None

if __name__=='__main__':
    try:main()
    except (d.Stop,KeyboardInterrupt) as error:
        print('STOP:',str(error) or 'Cancelled.',file=sys.stderr)
        sys.exit(1)
