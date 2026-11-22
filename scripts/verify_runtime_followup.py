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
FOLLOWUP = 'eebde4a9b3deb2a9d617e112151e3e16f3e6eae2'
FOLLOWUP_LOG_SHA256 = '1d1f088cc9f2dc87191cd2b96a2989dc9dce85a92a47e6ab766e4fa56d559388'
FOLLOWUP_BUILD_HASHES = {'core.log': '64c2b88b8829f82c7985058f3a83c8c506f22b07f6cc56780b26c8d439539e95', 'debug-build.log': 'b81d6a9d59315b23758d467c4e03aebdaa4ac11d24d24dc00a83e89f6814ba8a', 'release-build.log': 'fbb4d6150af1ee36f1f2e714a1e4915bd602d62c0a697d1290f05e275d55303f', 'personal-package.log': '1185f933b83698447f03b9b1245c878b39c8d9f8528c3733249253773625ce85', 'iphone11/package.json': 'f146c4c92384d51bd5e34a9f162515127657e4d14cda0e2c05bc5e77fc002265'}
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


def commit_available(commit):
    if subprocess.run(['git','cat-file','-e',commit+'^{commit}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:
        subprocess.run(['git','fetch','--no-tags','--depth=1','origin',commit],check=True,timeout=120)


def cases(text):
    return {status:Counter(re.findall(r"^Test Case '-\[([^\]]+)\]' " + status,text,re.MULTILINE))
            for status in ['started','passed','failed']}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-evidence',type=Path,required=True)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--focused-log',type=Path)
    selection.add_argument('--retained-followup-evidence',type=Path)
    args = parser.parse_args()
    commit_available(BASELINE)
    paths = subprocess.check_output(['git','diff','--name-only',BASELINE,'HEAD','--'],text=True).splitlines()
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
    if args.retained_followup_evidence:
        commit_available(FOLLOWUP)
        require(not subprocess.check_output(['git','diff','--name-only','HEAD','--'],text=True).strip(),'Validate retained evidence on a clean checkout before generating projects')
        followup_paths = subprocess.check_output(['git','diff','--name-only',FOLLOWUP,'HEAD','--'],text=True).splitlines()
        require(set(followup_paths).issubset({'.github/workflows/functional-port.yml','scripts/verify_runtime_followup.py','docs/CURRENT_STATUS.md'}),
                'Product or UI test source differs from the passed follow-up; run affected tests again')
        focused_log = args.retained_followup_evidence/'corrected-scenarios.log'
        require(hashlib.sha256(focused_log.read_bytes()).hexdigest() == FOLLOWUP_LOG_SHA256,'Retained follow-up log hash mismatch')
        require(set(FOLLOWUP_BUILD_HASHES) == {'core.log','debug-build.log','release-build.log','personal-package.log','iphone11/package.json'},'Missing sealed Apple build evidence')
        for name,digest in FOLLOWUP_BUILD_HASHES.items():
            require(hashlib.sha256((args.retained_followup_evidence/name).read_bytes()).hexdigest() == digest,'Retained Apple build evidence hash mismatch: '+name)
        package = json.loads((args.retained_followup_evidence/'iphone11/package.json').read_text())
        require(package['source_sha'] == FOLLOWUP,'Retained evidence came from a different source')
    else:
        focused_log = args.focused_log
    focused = cases(focused_log.read_text())
    require(set(focused['started']) == TARGETS and focused['started'] == focused['passed'] and not focused['failed'],'Affected UI scenarios did not all pass')
    require(all(focused['passed'][name] == 2 for name in TARGETS),'Both affected UI scenarios must pass two scheduled iterations')
    text = focused_log.read_text()
    require('-complete.xctestrun' in text,'Follow-up did not use the complete-run checkpoint assertion configuration')
    output = Path('.local-checks/ci/runtime-coverage.json')
    report = dict(kind='complete-run-plus-bounded-ui-followup',source_sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        baseline_source_sha=BASELINE,baseline_run_id=BASELINE_RUN,baseline_log_hashes=HASHES,
        changed_paths=paths,prior_core_passed=330,prior_hosted_passed=232,prior_ui_passed=32,
        affected_ui_passed=sorted(TARGETS),affected_ui_iterations=2,covered_ui_scenarios=34,
        prior_complete_run_status='failed-two-ui-scenarios',current_full_suite_rerun=False,
        current_ui_rerun=not bool(args.retained_followup_evidence),
        focused_source_sha=FOLLOWUP if args.retained_followup_evidence else subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        focused_log_sha256=hashlib.sha256(focused_log.read_bytes()).hexdigest(),
        retained_build_log_hashes=FOLLOWUP_BUILD_HASHES if args.retained_followup_evidence else {},
        checkpoint_assertions=True,product_screenshots=False)
    output.parent.mkdir(parents=True,exist_ok=True); output.write_text(json.dumps(report,indent=2)+'\n')
    print('Verified unchanged protocol/hosted/other UI evidence and both affected UI scenarios twice; 34 UI scenarios covered',flush=True)


if __name__ == '__main__': main()
