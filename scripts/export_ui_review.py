#!/usr/bin/env python3
"""Export named, unmodified native screenshots from the SAME XCTest run."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile


def export_review(result, output, *, tests_succeeded, source_sha=None):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    source_sha = source_sha or os.environ.get('GITHUB_SHA') or subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    source = Path(__file__).resolve().parents[1] / 'Tests/EntrixyUITests/NavigationUITests.swift'
    required = set(re.findall(r'reviewCapture\("([a-z0-9-]+)"\)', source.read_text()))
    frames = {}
    with tempfile.TemporaryDirectory(prefix='entrixy-ui-attachments-') as temporary:
        subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', temporary], check=True, timeout=120)
        root = Path(temporary)
        manifest = json.loads((root / 'manifest.json').read_text())
        for test in manifest:
            for attachment in test.get('attachments', []):
                name = attachment.get('suggestedHumanReadableName', '')
                match = re.match(r'^review-([a-z0-9-]+)(?:_|\.png$)', name)
                if not match:
                    continue
                state = match.group(1)
                filename = attachment['exportedFileName']
                if state not in required or Path(filename).name != filename:
                    raise RuntimeError('Unexpected UI capture attachment name')
                path = root / filename
                data = path.read_bytes()
                if data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
                    raise RuntimeError('UI review attachment is not an original PNG')
                width, height = struct.unpack('>II', data[16:24])
                if not (1000 <= width <= 1400 and 2300 <= height <= 3000):
                    raise RuntimeError('Unexpected iPhone 16 screenshot dimensions')
                digest = hashlib.sha256(data).hexdigest()
                if state in frames:
                    raise RuntimeError('Duplicate review state in a single test run: ' + state)
                destination = output / ('iphone16-light-' + state + '-' + source_sha[:7] + '.png')
                shutil.copyfile(path, destination)
                frames[state] = dict(screen=state, file=destination.name, sha256=digest, source_sha=source_sha,
                                     width=width, height=height, device='iphone16', appearance='light',
                                     test_identifier=test.get('testIdentifier'), native_xctest=True)
    missing = sorted(required - frames.keys())
    complete = tests_succeeded and not missing
    report = dict(kind='native-ui-checkpoints', source_sha=source_sha, tests_succeeded=tests_succeeded,
                  complete=complete, visual_review='pending', full_android_parity='pending',
                  captures=[frames[name] for name in sorted(frames)], missing_states=missing)
    (output / 'review.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f'Exported {len(frames)}/{len(required)} original native UI checkpoints; tests succeeded: {tests_succeeded}', flush=True)
    if tests_succeeded and missing:
        raise RuntimeError('UI suite passed without all requested screenshots: ' + ', '.join(missing))
    return report
