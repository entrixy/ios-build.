#!/usr/bin/env python3
"""Combine immutable complete-run evidence with checks of its affected UI paths.

This is a bounded follow-up to c8b3b63, not a substitute for a new full run after
unrelated application, protocol, dependency, resource or hosted-test changes.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess

BASELINE = 'c8b3b6372b74d14c6c9a3d4120c80b07387bf1da'
BASELINE_RUN = 45022342509
HASHES = {
    'core.log':'0182b195dc0fae403444789eb37c53dd932767528bdadaad048f6233bcf27ee3',
    'application-tests.log':'11bd52ebe2b8c120172a21c02ef786fe245bebac083123a3b71cf05a6052d748',
}
TARGETS = {
    'EntrixyUITests.NavigationUITests testActualWebhookEditorContainsAndroidFieldsAndAutomationRoute',
    'EntrixyUITests.NavigationUITests testOwnedBLEInformationUsesSeparateActionAndDoesNotInventUnobservedReadings',
}
ALLOWED = {
    'App/AutomationRouteMap.swift',
    'Tests/EntrixyUITests/NavigationUITests.swift',
    'scripts/test_simulator.py',
    'scripts/verify_runtime_followup.py',
    '.github/workflows/functional-port.yml',
    'docs/CURRENT_STATUS.md',
}


def require(condition,message):
    if not condition: raise ValueError(message)


def validate_paths(paths):
    require(set(paths).issubset(ALLOWED),'Unrelated source changed; a new complete run is required')


def cases(text):
    return {status:Counter(re.findall(r"^Test Case '-\[([^\]]+)\]' " + status,text,re.MULTILINE))
            for status in ['started','passed','failed']}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-evidence',type=Path,required=True)
    parser.add_argument('--focused-log',type=Path,required=True)
    args = parser.parse_args()
    if subprocess.run(['git','cat-file','-e',BASELINE+'^{commit}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:
        subprocess.run(['git','fetch','--no-tags','--depth=1','origin',BASELINE],check=True,timeout=120)
    paths = subprocess.check_output(['git','diff','--name-only',BASELINE,'--'],text=True).splitlines()
    validate_paths(paths)
    logs = {}
    for name,digest in HASHES.items():
        data = (args.baseline_evidence/name).read_bytes()
        require(hashlib.sha256(data).hexdigest() == digest,'Previous evidence hash mismatch: '+name)
        logs[name] = cases(data.decode('utf-8',errors='replace'))
    core = logs['core.log']
    require(len(core['started']) == 330 and core['started'] == core['passed'] and not core['failed'],'Previous protocol core did not pass completely')
    complete = logs['application-tests.log']
    native = {name for name in complete['started'] if name.startswith('EntrixyAppTests.')}
    ui = set(complete['started'])-native
    require(len(native) == 232 and native.issubset(complete['passed']) and not native.intersection(complete['failed']),'Previous hosted application checks were incomplete')
    require(len(ui) == 34 and set(complete['failed']) == TARGETS and ui-TARGETS == ui.intersection(complete['passed']),'Previous UI run has additional or missing failures')
    focused = cases(args.focused_log.read_text())
    require(set(focused['started']) == TARGETS and focused['started'] == focused['passed'] and not focused['failed'],'Affected UI scenarios did not all pass')
    require(all(focused['passed'][name] == 2 for name in TARGETS),'Both affected UI scenarios must pass two scheduled iterations')
    text = args.focused_log.read_text()
    require('-complete.xctestrun' in text,'Follow-up did not use the complete-run checkpoint assertion configuration')
    output = Path('.local-checks/ci/runtime-coverage.json')
    report = dict(kind='complete-run-plus-bounded-ui-followup',source_sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        baseline_source_sha=BASELINE,baseline_run_id=BASELINE_RUN,baseline_log_hashes=HASHES,
        changed_paths=paths,prior_core_passed=330,prior_hosted_passed=232,prior_ui_passed=32,
        affected_ui_passed=sorted(TARGETS),affected_ui_iterations=2,covered_ui_scenarios=34,
        prior_complete_run_status='failed-two-ui-scenarios',current_full_suite_rerun=False,
        checkpoint_assertions=True,product_screenshots=False)
    output.parent.mkdir(parents=True,exist_ok=True); output.write_text(json.dumps(report,indent=2)+'\n')
    print('Verified unchanged protocol/hosted/other UI evidence and both affected UI scenarios twice; 34 UI scenarios covered',flush=True)


if __name__ == '__main__': main()
