#!/usr/bin/env python3
"""Run hosted native unit tests on a disposable simulator, isolated from live preview."""
import argparse
import hashlib
import json
import plistlib
import os
from pathlib import Path
import subprocess
import struct
import shutil
from capture_simulator import create_booted_device, cleanup_device
from export_ui_review import export_review
from prepare_review_simulator import prepared_device
from run_xctest import run_xctest


def device_screen_probe(device):
    """Read the full native renderer without reopening or replaying a scenario.

    XCUIScreen's current iPhone16 PNGs are1178 pixels wide. Keep that evidence
    untouched and measure simctl separately before choosing Store assets.
    This post-test diagnostic may show another foreground surface; it is never
    automatically treated as a gallery or App Store product screenshot.
    """
    root = Path('.local-checks/ci'); root.mkdir(parents=True, exist_ok=True)
    target = root / 'native-device-probe.png'
    subprocess.run(['xcrun','simctl','io',device,'screenshot','--type=png',str(target)],check=True,timeout=30)
    data = target.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n' or len(data) < 29:
        raise RuntimeError('Invalid native renderer probe')
    width,height = struct.unpack('>II',data[16:24])
    report = {'kind':'native-renderer-diagnostic','width':width,'height':height,
        'has_alpha_channel':data[25] in [4,6], 'sha256':hashlib.sha256(data).hexdigest(),
        'matches_iphone16_store_size':(width,height)==(1179,2556),
        'product_content_review':'pending','is_submission_asset':False,
        'replayed_or_relaunched':False}
    (root / 'native-device-probe.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Full native renderer probe:',width,height,'; product/content acceptance remains pending',flush=True)


def review_test_products(products, *, capture=True):
    candidates = [path for path in products.glob('*.xctestrun') if not path.name.endswith(('-review.xctestrun','-complete.xctestrun'))]
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
    environment = ui_targets[0].setdefault('EnvironmentVariables', {})
    environment['ENTRIXY_REVIEW_CAPTURE'] = '1' if capture else '0'
    if not capture:
        environment['ENTRIXY_CHECKPOINT_ASSERTIONS'] = '1'
    # Keep __TESTROOT__ relative paths valid: the copy stays beside the original.
    destination = source.with_name(source.stem + ('-review' if capture else '-complete') + '.xctestrun')
    destination.write_bytes(plistlib.dumps(data))
    return destination


def retain_fixture_input_trace(device, *, review):
    """Read only the fixed non-personal trace from this owned simulator fixture."""
    try:
        container = Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,'com.entrixy.ios','data'],text=True,timeout=15).strip())
        trace = container/'Library/Caches/stage-two-input.jsonl'
        if trace.is_file() and trace.stat().st_size <= 1_048_576:
            destination = Path('.local-checks/ci')/('review-native-input.jsonl' if review else 'focused-native-input.jsonl')
            destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(trace,destination)
            print('Retained isolated native input trace:',destination,flush=True)
    except (OSError,subprocess.SubprocessError) as error:
        print('Could not retain isolated native input trace:',type(error).__name__,flush=True)


def main():
    parser = argparse.ArgumentParser()
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--only-native", action="store_true", help="Run hosted native tests without UI automation")
    selection.add_argument("--only-ui", action="store_true", help="Run unchanged UI assertions on a fresh runner without hosted unit tests")
    parser.add_argument("--use-built-tests", action="store_true", help="Run the existing build-for-testing products without rebuilding")
    parser.add_argument('--review-captures', action='store_true', help='Capture named UI checkpoints during the same native/UI test pass')
    parser.add_argument('--complete-suite', action='store_true', help='Run all hosted/UI assertions without screenshot collection')
    parser.add_argument('--checkpoint-assertions',action='store_true',help='Use the complete suite checkpoint assertions during an explicitly selected UI follow-up, without screenshots')
    parser.add_argument('--prepared-device',type=Path,help='Use the verified source/runtime-matched device prepared before compilation')
    parser.add_argument('--test',action='append',default=[],help='Exact EntrixyUITests method for focused diagnosis; never exports a gallery')
    parser.add_argument('--iterations',type=int,default=1,help='Repeat every selected diagnostic test; not a retry-on-failure')
    parser.add_argument('--keep-prepared-device',action='store_true',help='Leave the owned prepared device for the next pass; workflow finally must clean up')
    args = parser.parse_args()
    if args.checkpoint_assertions and (not args.test or not args.use_built_tests or args.review_captures or args.complete_suite):
        parser.error('--checkpoint-assertions requires selected built tests without captures or complete-suite')
    if args.complete_suite and (args.review_captures or args.only_native or args.only_ui or args.test):
        parser.error('--complete-suite cannot be combined with partial selections or screenshot collection')
    if args.test and (args.review_captures or args.complete_suite or any(not name.startswith(('EntrixyUITests/NavigationUITests/test','EntrixyAppTests/')) or not name.replace('/','').replace('_','').isalnum() for name in args.test)):
        parser.error('--test requires exact native/UI targets without complete-suite or captures')
    if not 1 <= args.iterations <= 3 or (args.iterations != 1 and not args.test):
        parser.error('--iterations 2 or 3 requires explicit diagnostic --test selection')
    if args.keep_prepared_device and (not args.prepared_device or not (args.test or args.review_captures or args.complete_suite)):
        parser.error('--keep-prepared-device requires a prepared device and an explicit diagnostic or complete review pass')
    if args.review_captures and (not args.use_built_tests or args.only_native):
        parser.error('--review-captures requires --use-built-tests and UI tests')
    if args.use_built_tests:
        products = Path('.local-checks/DerivedData/Build/Products')
        if not list(products.glob('*.xctestrun')):
            parser.error('--use-built-tests requires build-for-testing products in .local-checks/DerivedData')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True, timeout=60).strip()
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json'], timeout=60))['runtimes']
    runtime = next(r['identifier'] for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier'] and (r['version'] == sdk or r['version'].startswith(sdk + '.')))
    device = prepared_device(args.prepared_device,runtime) if args.prepared_device else create_booted_device('isolated unit tests', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16', runtime, appearance='light')
    result = Path('.local-checks/TestResults/combined-review.xcresult')
    tests_succeeded = False
    try:
        command = ['xcodebuild', '-destination', 'id=' + device,
            '-parallel-testing-enabled', 'NO', 'test-without-building' if args.use_built_tests else 'test']
        if args.review_captures or args.complete_suite or args.checkpoint_assertions:
            result.parent.mkdir(parents=True,exist_ok=True)
            if result.exists():
                raise RuntimeError('Review result already exists; do not mix test runs')
            command += ['-xctestrun',str(review_test_products(Path('.local-checks/DerivedData/Build/Products'),capture=args.review_captures)),'-resultBundlePath',str(result)]
        else:
            command += ['-project',os.environ.get('ENTRIXY_TEST_PROJECT','Entrixy.xcodeproj'),'-scheme','EntrixyTests','-configuration','Debug',
                        '-derivedDataPath','.local-checks/DerivedData','CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-']
        if args.test:
            command.extend('-only-testing:'+name for name in args.test)
            if args.iterations > 1:
                command.extend(['-test-iterations',str(args.iterations)])
        elif args.only_ui:
            command.append('-only-testing:EntrixyUITests')
        elif args.only_native:
            command.append('-only-testing:EntrixyAppTests')
        # The complete suite also includes native map gestures and bounded
        # counters. Keep a finite 90-minute budget on slower hosted Macs;
        # launch detection, assertions and the no-replay policy are unchanged.
        run_xctest(command,timeout=5400 if args.review_captures or args.complete_suite else 1800,
                   report_path=Path('.local-checks/ci/xctest-progress.json'))
        tests_succeeded = True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        # Retain the exact failed UI frame/hierarchy instead of guessing from a
        # different capture process. Diagnostics must not hide the test failure.
        results = [result] if (args.review_captures or args.complete_suite or args.checkpoint_assertions) and result.exists() else list(Path('.local-checks/DerivedData/Logs/Test').glob('*.xcresult'))
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
            if args.test or args.review_captures:
                retain_fixture_input_trace(device,review=args.review_captures)
            if args.review_captures:
                try: device_screen_probe(device)
                except (OSError,RuntimeError,subprocess.SubprocessError) as error:
                    print('Could not read native renderer probe:',error,flush=True)
            if args.review_captures and result.exists():
                if tests_succeeded:
                    export_review(result,Path('.local-checks/ci/screenshots'),tests_succeeded=True)
                else:
                    try: export_review(result,Path('.local-checks/ci/screenshots'),tests_succeeded=False)
                    except Exception as error: print('Could not export partial UI review:',error,flush=True)
        finally:
            if not args.keep_prepared_device:
                cleanup_device(device)


if __name__ == '__main__':
    main()
