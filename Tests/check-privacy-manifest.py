#!/usr/bin/env python3
"""Offline manifest contract and optional built-app parity check. No user data/network.

Run: python3 Tests/check-privacy-manifest.py [--app /path/to/Feast.app]
The declarations are justified in docs/PRIVACY_MANIFEST_REVIEW.md. Re-review that
matrix when adding collection, providers, purposes, or enabling gated features.
"""
import argparse
import copy
import json
import plistlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TYPE = "NSPrivacyCollectedDataType"
PURPOSE = TYPE + "Purpose"
FUNCTIONALITY = PURPOSE + "AppFunctionality"
PERSONALIZATION = PURPOSE + "ProductPersonalization"
EXPECTED = {
    TYPE + name: {FUNCTIONALITY, PERSONALIZATION} if name in
    {"OtherUserContent", "SearchHistory"} else {FUNCTIONALITY}
    for name in ("Name", "OtherUserContent", "SearchHistory", "UserID", "DeviceID",
                 "ProductInteraction", "OtherUsageData", "OtherDiagnosticData")
}
REQUIRED_APIS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
    "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(manifest):
    require(type(manifest) is dict, "Manifest must be a dictionary")
    require(set(manifest) <= {"NSPrivacyTracking", "NSPrivacyTrackingDomains",
                              "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"},
            "Unknown top-level privacy key")
    require(manifest.get("NSPrivacyTracking") is False, "Tracking must remain false")
    require(manifest.get("NSPrivacyTrackingDomains", []) == [], "Unexpected tracking domains")
    entries = manifest.get("NSPrivacyCollectedDataTypes")
    require(type(entries) is list and len(entries) == len(EXPECTED), "Missing/extra collected types")
    seen = set()
    for entry in entries:
        require(type(entry) is dict and set(entry) ==
                {TYPE, TYPE + "Linked", TYPE + "Tracking", TYPE + "Purposes"},
                "Each collected type must have exactly the four TN3184 keys")
        name = entry[TYPE]
        require(type(name) is str and name in EXPECTED and name not in seen,
                "Unreviewed or duplicate data type")
        seen.add(name)
        require(entry[TYPE + "Linked"] is True, "Collected records are linked, not anonymous")
        require(entry[TYPE + "Tracking"] is False, "No tracking is declared")
        purposes = entry[TYPE + "Purposes"]
        require(type(purposes) is list and all(type(p) is str for p in purposes),
                "Purposes must be an array of strings")
        require(len(purposes) == len(set(purposes)) and set(purposes) == EXPECTED[name],
                "Missing, duplicate, or unreviewed purpose")
    api_entries = manifest.get("NSPrivacyAccessedAPITypes")
    require(type(api_entries) is list and len(api_entries) == len(REQUIRED_APIS),
            "Required-reason declarations changed")
    require(all(type(e) is dict and set(e) ==
                {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"} for e in api_entries),
            "Malformed required-reason declaration")
    require({e["NSPrivacyAccessedAPIType"]: e["NSPrivacyAccessedAPITypeReasons"]
             for e in api_entries} == REQUIRED_APIS, "Required-reason values changed")


def check_resource_membership():
    raw = subprocess.check_output(["plutil", "-convert", "json", "-o", "-",
                                   str(ROOT / "Feast.xcodeproj/project.pbxproj")])
    objects = json.loads(raw)["objects"]
    targets = [(key, value) for key, value in objects.items()
               if value.get("isa") == "PBXNativeTarget" and value.get("name") == "Feast"]
    require(len(targets) == 1, "Expected one Feast app target")
    target_id, target = targets[0]
    groups = [objects[key] for key in target.get("fileSystemSynchronizedGroups", [])
              if objects[key].get("path") == "Feast"]
    require(len(groups) == 1, "Feast resources must belong to the synchronized app target")
    for key in groups[0].get("exceptions", []):
        exception = objects[key]
        if exception.get("target") == target_id:
            require("PrivacyInfo.xcprivacy" not in exception.get("membershipExceptions", []),
                    "Privacy manifest excluded from app resources")
    require(any(objects[key].get("isa") == "PBXResourcesBuildPhase"
                for key in target["buildPhases"]), "Missing resources build phase")


def check_rejected_mutations(manifest):
    fixtures = []
    bad = copy.deepcopy(manifest); bad["NSPrivacyCollectedDataTypo"] = []; fixtures.append(bad)
    bad = copy.deepcopy(manifest)
    content = next(e for e in bad["NSPrivacyCollectedDataTypes"] if e[TYPE] == TYPE + "OtherUserContent")
    content[TYPE + "Purposes"] = [FUNCTIONALITY]; fixtures.append(bad)
    bad = copy.deepcopy(manifest); bad.pop("NSPrivacyCollectedDataTypes"); fixtures.append(bad)
    bad = copy.deepcopy(manifest); bad["NSPrivacyTracking"] = "false"; fixtures.append(bad)
    for key, value in ((TYPE + "Linked", False), (TYPE + "Tracking", "false"),
                       (TYPE + "Purposes", [FUNCTIONALITY, PERSONALIZATION]), (TYPE, TYPE + "Invented")):
        bad = copy.deepcopy(manifest); bad["NSPrivacyCollectedDataTypes"][0][key] = value; fixtures.append(bad)
    bad = copy.deepcopy(manifest)
    bad["NSPrivacyCollectedDataTypes"][1] = copy.deepcopy(bad["NSPrivacyCollectedDataTypes"][0])
    fixtures.append(bad)
    bad = copy.deepcopy(manifest); bad["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPITypeReasons"] = []; fixtures.append(bad)
    for fixture in fixtures:
        try:
            validate(fixture)
        except ValueError:
            continue
        raise ValueError("Validator accepted a malformed or unreviewed manifest")
    print(f"PASS {len(fixtures)} in-memory negative manifest cases")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Built Feast.app or archived Products/Applications/Feast.app")
    args = parser.parse_args()
    manifest = plistlib.loads((ROOT / "Feast/PrivacyInfo.xcprivacy").read_bytes())
    validate(manifest)
    check_resource_membership()
    check_rejected_mutations(manifest)
    print("PASS eight reviewed collected types, purposes, linkage, no tracking, existing API reasons and target membership")
    if args.app:
        bundled = plistlib.loads((args.app / "PrivacyInfo.xcprivacy").read_bytes())
        validate(bundled)
        require(bundled == manifest, "Built app manifest differs from the reviewed source")
        print("PASS built app contains the complete reviewed privacy manifest")
    else:
        print("NOT RUN built-app parity: pass --app for the final build/archive")


if __name__ == "__main__":
    main()
