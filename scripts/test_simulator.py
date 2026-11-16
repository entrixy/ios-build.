#!/usr/bin/env python3
"""Run hosted native unit tests on a disposable simulator, isolated from live preview."""
import json
from pathlib import Path
import subprocess


def main():
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
    runtime = next(r['identifier'] for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier'] and (r['version'] == sdk or r['version'].startswith(sdk + '.')))
    device = subprocess.check_output(['xcrun', 'simctl', 'create', 'Entrixy isolated unit tests', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16', runtime], text=True).strip()
    try:
        subprocess.run(['xcodebuild', '-project', 'Entrixy.xcodeproj', '-scheme', 'EntrixyTests',
            '-configuration', 'Debug', '-destination', 'id=' + device,
            '-derivedDataPath', '.local-checks/DerivedData', '-parallel-testing-enabled', 'NO',
            'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'test'], check=True, timeout=1800)
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
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        subprocess.run(['xcrun', 'simctl', 'delete', device], check=True, timeout=30)


if __name__ == '__main__':
    main()
