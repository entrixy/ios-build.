#!/usr/bin/env python3
"""Run hosted native unit tests on a disposable simulator, isolated from live preview."""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess
from capture_simulator import create_booted_device, cleanup_device
from export_ui_review import export_review


def review_test_products(products):
    candidates = [path for path in products.glob('*.xctestrun') if not path.name.endswith('-review.xctestrun')]
    if len(candidates) != 1:
        raise RuntimeError('Expected one exact build-for-testing configuration')
    source = candidates[0]
    data = plistlib.loads(source.read_bytes())
    configurations = data.get('TestConfigurations')
    targets = ([target for configuration in configurations for target in configuration.get('TestTargets', [])]
               if configurations else [value for value in data.values() if isinstance(value, dict) and 'TestBundlePath' in value])
    ui_targets = [target for target in targets if 'EntrixyUITests' in str(target.get('TestBundlePath', ''))]
    if len(ui_targets) != 1:
        raise RuntimeError('Expected the compiled EntrixyUITests target')
    ui_targets[0].setdefault('EnvironmentVariables', {})['ENTRIXY_REVIEW_CAPTURE'] = '1'
    # Keep __TESTROOT__ relative paths valid: the copy stays beside the original.
    destination = source.with_name(source.stem + '-review.xctestrun')
    destination.write_bytes(plistlib.dumps(data))
    return destination


def main():
    parser = argparse.ArgumentParser()
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--only-native", action="store_true", help="Run hosted native tests without UI automation")
    selection.add_argument("--only-ui", action="store_true", help="Run unchanged UI assertions on a fresh runner without hosted unit tests")
    parser.add_argument("--use-built-tests", action="store_true", help="Run the existing build-for-testing products without rebuilding")
    parser.add_argument('--review-captures', action='store_true', help='Capture named UI checkpoints during the same native/UI test pass')
    args = parser.parse_args()
    if args.review_captures and (not args.use_built_tests or args.only_native):
        parser.error('--review-captures requires --use-built-tests and UI tests')
    if args.use_built_tests:
        products = Path('.local-checks/DerivedData/Build/Products')
        if not list(products.glob('*.xctestrun')):
            parser.error('--use-built-tests requires build-for-testing products in .local-checks/DerivedData')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
    runtime = next(r['identifier'] for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier'] and (r['version'] == sdk or r['version'].startswith(sdk + '.')))
    device = create_booted_device('isolated unit tests', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16', runtime)
    result = Path('.local-checks/TestResults/combined-review.xcresult')
    tests_succeeded = False
    try:
        subprocess.run(['xcrun','simctl','ui',device,'appearance','light'],check=True,timeout=30)
        command = ['xcodebuild', '-destination', 'id=' + device,
            '-parallel-testing-enabled', 'NO', 'test-without-building' if args.use_built_tests else 'test']
        if args.review_captures:
            result.parent.mkdir(parents=True,exist_ok=True)
            if result.exists():
                raise RuntimeError('Review result already exists; do not mix test runs')
            command += ['-xctestrun',str(review_test_products(Path('.local-checks/DerivedData/Build/Products'))),'-resultBundlePath',str(result)]
        else:
            command += ['-project','Entrixy.xcodeproj','-scheme','EntrixyTests','-configuration','Debug',
                        '-derivedDataPath','.local-checks/DerivedData','CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-']
        if args.only_ui:
            command.append('-only-testing:EntrixyUITests')
        elif args.only_native:
            command.append('-only-testing:EntrixyAppTests')
        subprocess.run(command, check=True, timeout=1800)
        tests_succeeded = True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        # Retain the exact failed UI frame/hierarchy instead of guessing from a
        # different capture process. Diagnostics must not hide the test failure.
        results = [result] if args.review_captures and result.exists() else list(Path('.local-checks/DerivedData/Logs/Test').glob('*.xcresult'))
        if results:
            result = max(results, key=lambda p: p.stat().st_mtime)
            destination = Path('.local-checks/ci/ui-failure-attachments')
            destination.mkdir(parents=True, exist_ok=True)
            try:
                subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments',
                    # Test teardown PNGs are keepAlways attachments, not Xcode
                    # issue attachments. --only-failures silently omitted them.
                    '--path', str(result), '--output-path', str(destination)], timeout=90)
            except (OSError, subprocess.TimeoutExpired) as diagnostic_error:
                print('Could not export failure attachments:', diagnostic_error, flush=True)
        raise
    finally:
        try:
            if args.review_captures and result.exists():
                if tests_succeeded:
                    export_review(result,Path('.local-checks/ci/screenshots'),tests_succeeded=True)
                else:
                    try: export_review(result,Path('.local-checks/ci/screenshots'),tests_succeeded=False)
                    except Exception as error: print('Could not export partial UI review:',error,flush=True)
        finally:
            cleanup_device(device)


if __name__ == '__main__':
    main()
