#!/bin/zsh
# Native touch tests against real Ask views, synthetic stores and a local provider.
# Always uses a new app identity and disposable simulator; no real user app/data.
set -euo pipefail
root=${0:A:h:h}
work=$(mktemp -d /private/tmp/feast-keyboard-tests.XXXXXX)
sim=""
cleanup() {
  if [[ -n "$sim" ]]; then
    container=$(xcrun simctl get_app_container "$sim" "$bundle" data 2>/dev/null || true)
    [[ -n "$container" && -f "$container/Documents/keyboard.log" ]] && cp "$container/Documents/keyboard.log" "$work/keyboard.log" || true
    xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
    xcrun simctl delete "$sim" >/dev/null 2>&1 || true
  fi
  print "Keyboard regression artifacts retained at $work"
}
trap cleanup EXIT
unset FEAST_UPGRADE_COPY_DIR FEAST_TEST_RECOVERY FEAST_AUDIT_ANSWER_CASE
mkdir "$work/source"
ditto "$root/Feast" "$work/source/Feast"
ditto "$root/Feast.xcodeproj" "$work/source/Feast.xcodeproj"
cp "$root/Tests/Fixtures/AskKeyboardApp.swift" "$work/source/Feast/App/FeastApp.swift"
cp "$root/Tests/Fixtures/AskKeyboardGestureTests.swift" "$work/source/KeyboardGestureTests.swift"
git -C "$root" rev-parse HEAD > "$work/source-revision.txt"
git -C "$root" diff -- Feast Feast.xcodeproj > "$work/current-source.patch"
tag=$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')
bundle="com.jongalante.Feast.KeyboardRegression.r${tag}"
python3 "$root/Tests/Fixtures/configure-ask-keyboard-tests.py" "$work/source" "$bundle"
python3 - "$work/source/Feast/Info.plist" <<'PY'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f: value=plistlib.load(f)
for key in list(value):
    if key.startswith('FeastAsk') or 'CloudKit' in key or key in ('CKSharingSupported','UIBackgroundModes'):
        del value[key]
with open(p,'wb') as f: plistlib.dump(value,f)
PY
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
sim=$(xcrun simctl create "Feast Keyboard $tag" "$device" "$runtime")
print "$sim" > "$work/simulator-id.txt"
print "$bundle" > "$work/bundle-id.txt"
print "Artifacts: $work"
xcodebuild test -project "$work/source/Feast.xcodeproj" -scheme Feast \
  -configuration "${FEAST_TEST_CONFIGURATION:-Debug}" -destination "platform=iOS Simulator,id=$sim" \
  -derivedDataPath "$work/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS= \
  INFOPLIST_KEY_FeastCloudKitContainerIdentifier= -parallel-testing-enabled NO \
  -only-testing:KeyboardGestureTests -resultBundlePath "$work/KeyboardTests.xcresult" > "$work/tests.log" 2>&1
print "PASS native Ask keyboard touch regressions"
