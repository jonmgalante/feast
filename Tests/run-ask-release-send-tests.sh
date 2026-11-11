#!/bin/zsh
# Actual app sources, synthetic stores and transport; never install over a user's app.
set -euo pipefail
root=${0:A:h:h}
source_ref=""
expect_original_crash=0
while (( $# )); do
  case "$1" in
    --source-ref) (( $# >= 2 )) || exit 2; source_ref=$2; shift 2 ;;
    --expect-original-crash) expect_original_crash=1; shift ;;
    *) print -u2 "Unknown argument: $1"; exit 2 ;;
  esac
done
if (( expect_original_crash )) && [[ -z "$source_ref" ]]; then print -u2 "Expected-crash mode requires --source-ref"; exit 2; fi
work=$(mktemp -d /private/tmp/feast-release-send.XXXXXX)
sim=""
cleanup() {
  if [[ -n "$sim" ]]; then
    xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
    xcrun simctl delete "$sim" >/dev/null 2>&1 || true
  fi
  print "Regression artifacts retained at $work"
}
trap cleanup EXIT
unset FEAST_UPGRADE_COPY_DIR FEAST_TEST_RECOVERY FEAST_AUDIT_ANSWER_CASE
mkdir "$work/source"
if [[ -n "$source_ref" ]]; then
  revision=$(git -C "$root" rev-parse --verify "${source_ref}^{commit}")
  git -C "$root" archive "$revision" Feast Feast.xcodeproj | tar -x -C "$work/source"
  print "$revision" > "$work/source-revision.txt"
else
  ditto "$root/Feast" "$work/source/Feast"
  ditto "$root/Feast.xcodeproj" "$work/source/Feast.xcodeproj"
  git -C "$root" diff -- Feast Feast.xcodeproj > "$work/current-source.patch"
  git -C "$root" rev-parse HEAD > "$work/source-revision.txt"
fi
cp "$root/Tests/Fixtures/AskReleaseSendApp.swift" "$work/source/Feast/App/FeastApp.swift"
# Remove real-service configuration in the disposable copy, never the checkout.
python3 - "$work/source/Feast/Info.plist" <<'PYINFO'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f: value=plistlib.load(f)
for key in list(value):
    if key.startswith('FeastAsk') or 'CloudKit' in key or key in ('CKSharingSupported','UIBackgroundModes'):
        del value[key]
with open(p,'wb') as f: plistlib.dump(value,f)
PYINFO
# Only local installed iOS runtimes; never download or boot an existing device.
xcrun simctl list runtimes --json > "$work/runtimes.json"
runtime=$(python3 - "$work/runtimes.json" "${FEAST_SIM_RUNTIME:-}" <<'PY'
import json,sys
rows=[r for r in json.load(open(sys.argv[1]))['runtimes'] if r.get('isAvailable') and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')]
if sys.argv[2]: rows=[r for r in rows if r['identifier']==sys.argv[2]]
if not rows: raise SystemExit('No matching installed iOS simulator runtime')
print(max(rows,key=lambda r:tuple(map(int,r['version'].split('.'))))['identifier'])
PY
)
device=${FEAST_SIM_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}
tag=$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')
bundle="com.jongalante.Feast.ReleaseSendRegression.r${tag}"
print "Artifacts: $work"
sim=$(xcrun simctl create "Feast Release Send $tag" "$device" "$runtime")
print "$sim" > "$work/simulator-id.txt"
print "$bundle" > "$work/bundle-id.txt"
# Explicitly disable durable recovery and non-Release flags. Inherit the real
# project's optimization/default-isolation/approachable-concurrency settings.
xcodebuild -project "$work/source/Feast.xcodeproj" -scheme Feast -configuration Release \
  -sdk iphonesimulator -destination "id=$sim" -derivedDataPath "$work/DerivedData" \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS= PRODUCT_BUNDLE_IDENTIFIER="$bundle" \
  INFOPLIST_KEY_FeastCloudKitContainerIdentifier= \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS= GCC_PREPROCESSOR_DEFINITIONS= \
  build > "$work/build.log" 2>&1
app="$work/DerivedData/Build/Products/Release-iphonesimulator/Feast.app"
[[ -d "$app" ]]
python3 - "$app/Info.plist" "$bundle" <<'PYBUILT'
import plistlib,sys
with open(sys.argv[1],'rb') as f: value=plistlib.load(f)
assert value['CFBundleIdentifier']==sys.argv[2], 'Unexpected bundle identity'
assert not any(v for k,v in value.items() if k.startswith('FeastAsk') or 'CloudKit' in k), 'Live service configuration survived sanitization'
assert not value.get('CKSharingSupported') and not value.get('UIBackgroundModes'), 'Sharing/background configuration survived sanitization'
PYBUILT
xcrun simctl boot "$sim"
xcrun simctl bootstatus "$sim" -b > "$work/boot.log" 2>&1
for mode in offline answer large; do
  # Fresh dedicated sandbox each case: no imported history or keychain entries.
  xcrun simctl uninstall "$sim" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl install "$sim" "$app"
  args=()
  [[ "$mode" != offline ]] && args+=(-reproAnswer)
  [[ "$mode" == large ]] && args+=(-reproLarge)
  xcrun simctl launch "$sim" "$bundle" "${args[@]}" > "$work/launch-$mode.log" 2>&1
  container=$(xcrun simctl get_app_container "$sim" "$bundle" data)
  stages="$container/Documents/repro-stages.txt"
  passed=0
  for ((i=0;i<60;i++)); do
    if [[ -f "$stages" ]]; then
      cp "$stages" "$work/stages-$mode.txt"
      if grep -q HARNESS_ERROR "$stages" || grep -q PREPARE_FAILED "$stages"; then
        print -u2 "FAIL $mode: harness reported failure"; exit 1
      fi
      if grep -q FINISHED "$stages" && grep -q TRANSPORT_STUB_REACHED "$stages" && grep -q HISTORY_RELOAD_VERIFIED "$stages"; then
        if [[ "$mode" == offline ]] || grep -q ANSWER_RENDER_VERIFIED "$stages"; then passed=1; break; fi
      fi
    fi
    sleep 1
  done
  xcrun simctl terminate "$sim" "$bundle" >/dev/null 2>&1 || true
  if (( ! passed )); then
    if (( expect_original_crash )) && [[ "$mode" == offline ]] && [[ -f "$stages" ]] && ! grep -q TRANSPORT_STUB_REACHED "$stages"; then
      # Match this unique test bundle, not another app's historical crash.
      python3 - "$bundle" "$work" <<'PYCRASH'
import json,pathlib,sys
bundle,out=sys.argv[1],pathlib.Path(sys.argv[2])
for p in sorted((pathlib.Path.home()/'Library/Logs/DiagnosticReports').glob('Feast*.ips'),key=lambda p:p.stat().st_mtime,reverse=True):
    try:
        text=p.read_text(); header,body=text.split('\n',1)
        if json.loads(header).get('bundleID')!=bundle: continue
        # macOS may append a non-JSON System Profile after the report object.
        value=json.JSONDecoder().raw_decode(body.lstrip())[0];frames=value['threads'][value['faultingThread']]['frames']
        symbols='\n'.join(f.get('symbol','') for f in frames)
        if value.get('exception',{}).get('type')=='EXC_BAD_ACCESS' and 'URLRequest.httpBody.getter' in symbols and 'AskAgentProvider.privacyCheckedRemote.getter' in symbols:
            (out/'original-crash.ips').write_text(text)
            print('EXPECTED_CRASH_CONFIRMED: original privacy wrapper before transport')
            raise SystemExit(0)
    except (ValueError,KeyError,OSError): continue
raise SystemExit('Expected original crash signature not found; timeout alone is not a passing red test')
PYCRASH
      exit 0
    fi
    print -u2 "FAIL $mode: app crashed or timed out before verified completion"; exit 1
  fi
  if (( expect_original_crash )); then print -u2 "FAIL: archived code did not reproduce original crash"; exit 1; fi
  print "PASS Release $mode: real panel/provider completed through synthetic transport"
done
