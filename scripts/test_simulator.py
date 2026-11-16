#!/usr/bin/env python3
"""Run hosted native unit tests on a disposable simulator, isolated from live preview."""
import argparse
import json
from pathlib import Path
import subprocess
from capture_simulator import create_booted_device, cleanup_device


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only-ui", action="store_true", help="Run unchanged UI assertions on a fresh runner without hosted unit tests")
    args = parser.parse_args()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
    runtime = next(r['identifier'] for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier'] and (r['version'] == sdk or r['version'].startswith(sdk + '.')))
    device = create_booted_device('isolated unit tests', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16', runtime)
    try:
        command = ['xcodebuild', '-project', 'Entrixy.xcodeproj', '-scheme', 'EntrixyTests',
            '-configuration', 'Debug', '-destination', 'id=' + device,
            '-derivedDataPath', '.local-checks/DerivedData', '-parallel-testing-enabled', 'NO',
            'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'test']
        if args.only_ui:
            command.append('-only-testing:EntrixyUITests')
        subprocess.run(command, check=True, timeout=1800)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        # Retain the exact failed UI frame/hierarchy instead of guessing from a
        # different capture process. Diagnostics must not hide the test failure.
        results = list(Path('.local-checks/DerivedData/Logs/Test').glob('*.xcresult'))
        if results:
            result = max(results, key=lambda p: p.stat().st_mtime)
            destination = Path('.local-checks/ci/ui-failure-attachments')
            destination.mkdir(parents=True, exist_ok=True)
            try:
                subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments',
                    '--path', str(result), '--output-path', str(destination), '--only-failures'], timeout=90)
            except (OSError, subprocess.TimeoutExpired) as diagnostic_error:
                print('Could not export failure attachments:', diagnostic_error, flush=True)
        raise
    finally:
        cleanup_device(device)


if __name__ == '__main__':
    main()
