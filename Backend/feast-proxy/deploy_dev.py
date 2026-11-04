#!/usr/bin/env python3
"""User-operated, one-shot dev deployment. Python 3.9+, no token files or OAuth."""
import argparse
import getpass
import json
import re
import tempfile
import time
from datetime import datetime, timezone
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request

ACCOUNT = '994f7b36c1e049ae197d27009177804f'
WORKER = 'feast-proxy-dev'
STAGED = 'ef90b0d1-0fea-4020-870f-18d331483e14'
BASE = 'https://api.cloudflare.com/client/v4/accounts/' + ACCOUNT + '/workers/scripts/' + WORKER
ENDPOINT = 'https://feast-proxy-dev.jonmgalante.workers.dev'
ROOT = Path(__file__).resolve().parent

class Stop(Exception):
    pass

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

OPENER = urllib.request.build_opener(NoRedirect())

def fetch_json_once(url, token=None, method='GET', data=None):
    headers = {'Accept': 'application/json', 'Content-Type': 'application/json', 'User-Agent':'Feast-Dev-Verification/1.0'}
    if token is not None:
        if not url.startswith(BASE + '/'):
            raise Stop('Refused credential use outside the exact dev Worker API.')
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(url, headers=headers, method=method, data=data)
    try:
        with OPENER.open(request, timeout=30) as response:
            body = response.read(1048577)
            if len(body) > 1048576:
                raise Stop('Unexpected metadata response size; stopped.')
            parsed = json.loads(body)
            if token is not None:
                if parsed.get('success') is not True:
                    raise Stop('Cloudflare metadata verification failed; raw response suppressed.')
                return parsed['result']
            return response.status, parsed
    except urllib.error.HTTPError as error:
        if token is None:
            return error.code, None
        raise Stop('Cloudflare API HTTP %d; response suppressed. No automatic retry.' % error.code) from None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        raise Stop('Network/metadata result uncertain. Inspect deployed versions before retrying.') from None

def fetch_json(url, token=None, method='GET', data=None):
    # Retry reads only. Never automatically repeat a mutation.
    for attempt in range(4 if method == 'GET' else 1):
        try:
            return fetch_json_once(url, token, method, data)
        except Stop as error:
            retryable = ('Network/metadata' in str(error) or
                         any(('HTTP %d' % status) in str(error) for status in (429,500,502,503,504)))
            if method != 'GET' or not retryable or attempt == 3:
                raise
            print("Read verification temporarily unavailable; retrying read only (%d/3)." % (attempt + 1), flush=True)
            time.sleep(1 + attempt)


def checked_health(live):
    expected = {'service':'feast-proxy','revision':'step2-disabled-v1','liveAI':live,
                'requestsEnabled':live,'environment':'dev','model':'gpt-6-luna','totalCapMicroUSD':5000000}
    for attempt in range(5):
        status, health = fetch_json(ENDPOINT + '/health')
        if status == 200 and isinstance(health,dict) and all(health.get(key)==value for key,value in expected.items()):
            return
        if attempt < 4:
            time.sleep(2)
    raise Stop('Deployed health has not reached the expected dev configuration; no model test. Resume must recheck metadata.')


def latest_id(token):
    result = fetch_json(BASE + '/versions', token)
    items = result.get('items', []) if isinstance(result, dict) else result
    if not items or not isinstance(items[0].get('id'), str):
        raise Stop('Could not establish latest uploaded version.')
    return items[0]['id']

def secret_exists(version, name="OPENAI_API_KEY"):
    bindings = version.get('resources', {}).get('bindings', [])
    return any(x.get('name') == name and x.get('type') == 'secret_text' for x in bindings)

def deployment_state(token):
    result = fetch_json(BASE + '/deployments', token)
    items = result.get('deployments', []) if isinstance(result, dict) else result
    if not items:
        raise Stop('Could not establish active deployment.')
    versions = items[0].get('versions', [])
    if not versions:
        raise Stop('Could not establish active version traffic.')
    return [(v['version_id'], v['percentage']) for v in versions]

def preflight(token):
    if latest_id(token) != STAGED:
        raise Stop('Latest uploaded version differs from approved staged version. Coordinate before continuing.')
    if not secret_exists(fetch_json(BASE + '/versions/' + STAGED, token)):
        raise Stop('Approved staged version lacks encrypted OPENAI_API_KEY metadata. No deploy.')
    active = deployment_state(token)
    if len(active) != 1 or not active[0][0].startswith('304d5bba') or active[0][1] != 100:
        raise Stop('Live version differs from reviewed Hello World deployment. No deploy.')
    return active

def verify_configuration():
    if any(path.is_file() for pattern in ('.env', '.env.*', '.dev.vars', '.dev.vars.*') for path in ROOT.glob(pattern) if path.name != '.dev.vars.example'):
        raise Stop('Local secret/env files present; use the reviewed memory-only workflow, not automatic file loading.')
    config = json.loads((ROOT / 'wrangler.jsonc').read_text())
    dev = config['env']['dev']
    package = json.loads((ROOT / 'package.json').read_text())
    if (dev['name'] != WORKER or dev.get('account_id') != ACCOUNT or
        dev['vars'] != {'ENVIRONMENT':'dev','ENABLED':'false','TEST_MODE':'false'} or
        dev.get('workers_dev') is not True or config.get('observability', {}).get('enabled') is not False or
        config.get('send_metrics') is not False or
        dev.get('unsafe', {}).get('bindings') != [{'name':'OPENAI_API_KEY','type':'inherit'}] or
        package.get('devDependencies', {}).get('wrangler') != '4.151.3'):
        raise Stop('Configuration differs from reviewed disabled dev plan.')
    if (dev.get('durable_objects') != {'bindings':[{'name':'BUDGET','class_name':'BudgetLedger'}]} or
        dev.get('migrations') != [{'tag':'v1','new_sqlite_classes':['BudgetLedger']}]):
        raise Stop('Durable budget namespace/class/migration changed. No deployment or budget reset.')
    worker = (ROOT / 'worker.mjs').read_text()
    pricing = (ROOT / 'openai.mjs').read_text()
    identities = re.findall(r"idFromName\(([^)]*)\)", worker)
    if (identities != ["'shared-lifetime-v1'"] * 3 or
        any(value not in pricing for value in ('export const RESERVATION = 50000;', 'export const TOTAL_CAP = 5000000;', 'export const USER_CAP = 2500000;'))):
        raise Stop('Reviewed lifetime object identity or total budget policy changed. No deployment.')
    if dev.get('routes') or dev.get('route'):
        raise Stop('Routes/custom domains are outside this handoff.')

def run_deploy(token, original_active, expected_latest=STAGED, config_path=None, live=False):
    if latest_id(token) != expected_latest or deployment_state(token) != original_active:
        raise Stop('Concurrent version/deployment change detected. No deploy.')
    env = {k:v for k,v in os.environ.items() if not k.startswith(('CLOUDFLARE_', 'OPENAI_', 'WRANGLER_'))}
    env.update({'CLOUDFLARE_ACCOUNT_ID':ACCOUNT, 'CLOUDFLARE_API_TOKEN':token,
                'CI':'true', 'WRANGLER_SEND_METRICS':'false', 'WRANGLER_LOG':'error', 'WRANGLER_LOG_PATH':'/dev/null'})
    try:
        command = [str(ROOT / 'node_modules/.bin/wrangler'), 'deploy', '--env', 'dev']
        if config_path is not None:
            command += ['--config', str(config_path)]
        if live:
            command += ['--var', 'ENABLED:true', '--var', 'LIVE_AI:true', '--var', 'TEST_MODE:false']
        result = subprocess.run(command,
                                cwd=str(ROOT), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
    except subprocess.TimeoutExpired:
        raise Stop('Deployment timed out; outcome uncertain. Inspect version/deployment state, do not retry blindly.') from None
    finally:
        env.pop('CLOUDFLARE_API_TOKEN', None)
    if result.returncode != 0:
        # API state, not CLI exit alone, decides whether a mutation occurred.
        print('Deployment exit:', result.returncode, '; latest uploaded:', latest_id(token), '; active versions:', deployment_state(token))
        raise Stop('Wrangler failed. Output suppressed; metadata shown above. No automatic retry or permission expansion.')
    version_id = latest_id(token)
    for attempt in range(4):
        if version_id != expected_latest:
            break
        time.sleep(2)
        version_id = latest_id(token)
    if version_id == expected_latest:
        raise Stop('New protected version not established. Outcome uncertain.')
    if not secret_exists(fetch_json(BASE + '/versions/' + version_id, token)):
        raise Stop('Post-deploy encrypted secret metadata missing. STOP; do not activate or overwrite secrets.')
    deployed = deployment_state(token)
    for attempt in range(4):
        if deployed == [(version_id,100)]:
            break
        time.sleep(2)
        deployed = deployment_state(token)
    if deployed != [(version_id, 100)]:
        raise Stop('New version is not the sole active version; outcome uncertain.')
    checked_health(live)
    blocked, _ = fetch_json(ENDPOINT + '/v1/answer', method='POST', data=b'{}')
    if blocked != 401:
        raise Stop('Unauthenticated answer request did not fail closed. STOP.')
    print('Verified dev version:', version_id)
    (ROOT / '.feast-dev-status.json').write_text(json.dumps({'version':version_id,'liveAI':live,'verified':True}))
    if config_path is not None and not secret_exists(fetch_json(BASE + '/versions/' + version_id, token), 'CLIENT_TOKEN_HASHES_JSON'):
        raise Stop('Client hash binding missing after deployment; do not run a model test.')
    print('Encrypted bindings retained; live dispatch:', live, '; unauthenticated answer HTTP 401. No model calls from helper.')
    return version_id

def client_hashes(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 2048:
        raise Stop('Expected a small regular hash-only provisioning file.')
    try:
        users = json.loads(path.read_text())
    except (ValueError, OSError):
        raise Stop('Cannot read hash-only provisioning file.') from None
    if not isinstance(users, list) or len(users) != 2:
        raise Stop('Exactly two tester hash records required.')
    expected = {'feast-dev-tester-one', 'feast-dev-tester-two'}
    for user in users:
        if (not isinstance(user, dict) or set(user) != {'id','sha256','expiresAt'} or
            user.get('id') not in expected or not isinstance(user.get('sha256'), str) or
            re.fullmatch('[a-f0-9]{64}', user['sha256']) is None or
            user.get('expiresAt') != '2026-11-22T14:30:00Z'):
            raise Stop('Hash records differ from the reviewed credential specification. No provisioning.')
    if len({u['id'] for u in users}) != 2 or len({u['sha256'] for u in users}) != 2:
        raise Stop('Tester IDs and hashes must be distinct.')
    if datetime.now(timezone.utc) >= datetime(2026,11,22,14,30,tzinfo=timezone.utc):
        raise Stop('Reviewed tester credentials have expired.')
    return json.dumps(users, separators=(',', ':')).encode()


def complete_live(token, active, hashes):
    """Execute only after approval of client credential provisioning and $5 total tests."""
    if latest_id(token) != STAGED or deployment_state(token) != active:
        raise Stop('Concurrent changes before client-hash staging. No mutation.')
    env = {k:v for k,v in os.environ.items() if not k.startswith(('CLOUDFLARE_', 'OPENAI_', 'WRANGLER_'))}
    env.update({'CLOUDFLARE_ACCOUNT_ID':ACCOUNT, 'CLOUDFLARE_API_TOKEN':token,
                'CI':'true', 'WRANGLER_SEND_METRICS':'false', 'WRANGLER_LOG':'error', 'WRANGLER_LOG_PATH':'/dev/null'})
    try:
        result = subprocess.run([str(ROOT / 'node_modules/.bin/wrangler'), 'versions', 'secret', 'put',
            'CLIENT_TOKEN_HASHES_JSON', '--env', 'dev'], cwd=str(ROOT), env=env, input=hashes,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
    except subprocess.TimeoutExpired:
        raise Stop('Hash staging timed out; outcome uncertain. Inspect versions before retrying.') from None
    finally:
        env.pop('CLOUDFLARE_API_TOKEN', None)
    staged = latest_id(token)
    version = fetch_json(BASE + '/versions/' + staged, token)
    if (result.returncode != 0 or staged == STAGED or deployment_state(token) != active or
        not secret_exists(version) or not secret_exists(version, 'CLIENT_TOKEN_HASHES_JSON')):
        raise Stop('Hash staging not verified. Stop and inspect metadata; no automatic retry.')
    config = json.loads((ROOT / 'wrangler.jsonc').read_text())
    config['env']['dev']['unsafe']['bindings'].append({'name':'CLIENT_TOKEN_HASHES_JSON','type':'inherit'})
    # Only public configuration/hashes touch disk; raw credentials remain in child environment/Keychain.
    descriptor, name = tempfile.mkstemp(prefix='.feast-dev-handoff-', suffix='.json', dir=str(ROOT))
    try:
        with os.fdopen(descriptor, 'w') as file:
            json.dump(config, file)
        disabled = run_deploy(token, active, expected_latest=staged, config_path=name)
        run_deploy(token, [(disabled,100)], expected_latest=disabled, config_path=name, live=True)
        print('Dev activation verified. Run only the approved synthetic simulator test; $5 lifetime cap applies.')
    finally:
        Path(name).unlink(missing_ok=True)


def resume_live(token, repair=False):
    print('Reading existing dev deployment and encrypted binding metadata; no mutation yet.', flush=True)
    active = deployment_state(token)
    latest = latest_id(token)
    if len(active) != 1 or active[0] != (latest,100):
        raise Stop('Latest uploaded version is not the sole active version. No blind retry; inspect metadata.')
    version = fetch_json(BASE + '/versions/' + latest, token)
    names = ('OPENAI_API_KEY','CLIENT_TOKEN_HASHES_JSON')
    if not all(secret_exists(version,name) for name in names):
        raise Stop('Active version lacks an encrypted required binding. No recreation or activation.')
    status, health = fetch_json(ENDPOINT + '/health')
    print('Reconciled active dev version:', latest, '; encrypted OpenAI and tester bindings present.')
    (ROOT / '.feast-dev-status.json').write_text(json.dumps({'version':latest,'health':health,'verified':False}))
    if status != 200 or not isinstance(health,dict) or health.get('service') != 'feast-proxy' or health.get('environment') != 'dev' or health.get('totalCapMicroUSD') != 5000000:
        raise Stop('Active handler is not the reviewed dev budget configuration.')
    already_live = health.get('liveAI') is True and health.get('requestsEnabled') is True
    if already_live:
        checked_health(True)
        if not repair:
            print('Existing live dev deployment verified; no repeat deployment.')
            return
        if latest != '9bcef752-4b6e-4f72-bc7d-3dc0e655a315':
            raise Stop('Repair baseline changed. Metadata reconciled; inspect this version before any further deployment.')
        if "redirect:'manual'" not in (ROOT / 'openai.mjs').read_text():
            raise Stop('Tested redirect repair missing from local source.')
    if not already_live and (health.get('liveAI') is not False or health.get('requestsEnabled') is not False):
        raise Stop('Unexpected mixed activation state. No deployment.')
    # Existing disabled handler and both encrypted secrets have now been reconciled.
    # Same BUDGET class/migration/object name: existing reservations are retained.
    config = json.loads((ROOT / 'wrangler.jsonc').read_text())
    config['env']['dev']['unsafe']['bindings'].append({'name':'CLIENT_TOKEN_HASHES_JSON','type':'inherit'})
    descriptor, name = tempfile.mkstemp(prefix='.feast-dev-resume-',suffix='.json',dir=str(ROOT))
    try:
        with os.fdopen(descriptor,'w') as file: json.dump(config,file)
        repaired = run_deploy(token, active, expected_latest=latest, config_path=name, live=True)
        if repair:
            verify_synthetic_simulator(repaired)
    finally:
        Path(name).unlink(missing_ok=True)


def verify_synthetic_simulator(version):
    """One fixed synthetic request; no raw token ever leaves simulator Keychain."""
    simulator = '5325CDB2-9206-4CA4-B433-17DC93BC5A6B'
    bundle = 'com.jongalante.Feast'
    app = Path('/tmp/feast-live-debug/Build/Products/Debug-iphonesimulator/Feast.app')
    if not app.is_dir():
        raise Stop('Repair deployed, but compiled simulator app is missing. Build it before verification; do not repeat deployment.')
    def sim(*args, required=True):
        result = subprocess.run(['xcrun','simctl',*args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        if required and result.returncode:
            raise Stop('Simulator action failed after deployment: '+args[0]+'. No automatic repeat deployment.')
        return result.stdout.decode('utf8','replace').strip()
    print('Running one approved fictional-place simulator request; existing $5 lifetime cap applies.', flush=True)
    sim('terminate',simulator,bundle,required=False)
    sim('install',simulator,str(app))
    container = Path(sim('get_app_container',simulator,bundle,'data'))
    receipt = container/'Documents/FeastSyntheticLiveReceipt.json'
    started = time.time()
    sim('launch',simulator,bundle,'-feastSyntheticPreview','-feastHostedSynthetic','-feastAskQA','collection')
    for attempt in range(45):
        if receipt.is_file() and receipt.stat().st_mtime >= started:
            result = json.loads(receipt.read_text())
            (ROOT / '.feast-dev-status.json').write_text(json.dumps({'version':version,'liveAI':True,'verified':True,'simulator':result}))
            if result.get('httpStatus') != 200:
                raise Stop('Dev repair deployed. Synthetic request returned HTTP %s / %s; reservation remains held.' % (result.get('httpStatus'),result.get('reason',result.get('error','unknown'))))
            budget = result.get('budget',{})
            total = budget.get('reservedMicroUSD')
            if result.get('model') != 'gpt-6-luna' or not isinstance(total,int) or total > 5000000 or not result.get('summary'):
                raise Stop('HTTP200 received, but model/budget verification incomplete. No additional call made.')
            print('LIVE SIMULATOR VERIFIED:',result['model'],flush=True)
            print('Lifetime reservations: $%.2f; remaining shared allowance: $%.2f; estimated provider usage: $%.6f.' % (total/1000000,(5000000-total)/1000000,budget.get('estimatedUsageMicroUSD',0)/1000000),flush=True)
            return
        time.sleep(1)
    raise Stop('Dev repair deployed; simulator response not established within 45 seconds. No automatic second call or deployment.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deploy', action='store_true', help='Deploy reviewed dev handler after secure token re-entry; no model calls.')
    parser.add_argument('--complete-live', action='store_true', help='Approved client hashes plus disabled verification then live dev activation; no helper model calls.')
    parser.add_argument('--repair-live', action='store_true', help='Deploy tested repair from verified live baseline, then perform one synthetic simulator request.')
    parser.add_argument('--resume-live', action='store_true', help='Reconcile existing protected dev deployment and continue activation without recreating secrets.')
    parser.add_argument('--client-hashes', type=Path, help='Hash-only simulator provisioning file; never raw tokens.')
    args = parser.parse_args()
    if args.repair_live and (args.resume_live or args.complete_live or args.deploy or args.client_hashes is not None):
        raise Stop('Repair is separate from initial provisioning and other operations.')
    if args.resume_live and (args.complete_live or args.deploy or args.client_hashes is not None):
        raise Stop('Resume is separate from initial provisioning/deployment.')
    if args.complete_live != (args.client_hashes is not None) or (args.complete_live and args.deploy):
        raise Stop('Use --complete-live with --client-hashes, separately from --deploy.')
    hashes = client_hashes(args.client_hashes) if args.complete_live else None
    verify_configuration()
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        raise Stop('Run directly in a local Mac Terminal; never pass a token through chat, pipe or command arguments.')
    token = getpass.getpass('Existing Cloudflare dev-only token (hidden): ')
    if not token or token.startswith('sk-') or any(c.isspace() for c in token):
        raise Stop('Invalid token input; stopped without an API request.')
    try:
        if args.resume_live or args.repair_live:
            resume_live(token, repair=args.repair_live)
            return
        active = preflight(token)
        print('Approved staged secret version and unchanged Hello World deployment verified.')
        if args.complete_live:
            complete_live(token, active, hashes)
            return
        if not args.deploy:
            print('Read-only check complete. No deployment performed.')
            return
        # Parent coordinates account-task pause before this helper is started.
        print('Deploying only feast-proxy-dev, with live AI disabled and encrypted secret inheritance.')
        run_deploy(token, active)
    finally:
        token = None  # No credential persistence; Python cannot guarantee RAM zeroization.

if __name__ == '__main__':
    try:
        main()
    except (Stop, KeyboardInterrupt) as error:
        status_path = ROOT / '.feast-dev-status.json'
        try: status = json.loads(status_path.read_text()) if status_path.is_file() else {}
        except (ValueError,OSError): status = {}
        status.update({'verified':False,'error':str(error) or 'Cancelled.'})
        status_path.write_text(json.dumps(status))
        print('STOP:', str(error) or 'Cancelled.', file=sys.stderr)
        sys.exit(1)
