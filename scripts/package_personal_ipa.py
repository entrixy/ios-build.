#!/usr/bin/env python3
"""Archive real arm64 Release code and package for local Sideloadly signing."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile
from archive_device_release import bundle_record, verify_device_image


def inspect_personal(app):
    record = bundle_record(app)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if (info.get('EntrixyBuildVariant') != 'personal' or info.get('EntrixyAppGroup')
            or info.get('EntrixyPushEnvironment') or 'remote-notification' in info.get('UIBackgroundModes', [])
            or (app / 'PlugIns').exists() or record['minimum_ios'] != '16.0'):
        raise ValueError('Expected app-only iOS16 personal-signing product without paid-profile services')
    framework = app / 'Frameworks/VLCKit.framework'
    framework_info = plistlib.loads((framework / 'Info.plist').read_bytes())
    verify_device_image((framework / framework_info['CFBundleExecutable']).read_bytes())
    if not (app / 'VLCKit-LICENSE.txt').is_file():
        raise ValueError('Missing camera decoder license/source access notice')
    if any(path.name.startswith(('camera-decoder.', 'dash-init-', 'dash-seg-')) for path in app.rglob('*')):
        raise ValueError('Personal package contains unit-test camera fixtures')
    return record


def package(app, output):
    record = inspect_personal(app)
    if output.exists():
        raise ValueError('Refusing to overwrite an existing install package')
    staging = output.parent / 'staging'
    if staging.exists():
        raise ValueError('Refusing to mix a previous package staging directory')
    payload = staging / 'Payload'
    payload.mkdir(parents=True)
    try:
        shutil.copytree(app, payload / 'Entrixy.app', symlinks=True)
        subprocess.run(['ditto', '-c', '-k', '--keepParent', str(payload), str(output)], check=True, timeout=300)
        with zipfile.ZipFile(output) as archive:
            if archive.testzip() is not None or 'Payload/Entrixy.app/Info.plist' not in archive.namelist():
                raise ValueError('Invalid IPA archive')
            if plistlib.loads(archive.read('Payload/Entrixy.app/Info.plist'))['CFBundleIdentifier'] != record['bundle_id']:
                raise ValueError('Packaged application differs from verified archive')
    finally:
        shutil.rmtree(staging)
    return record


def main():
    archive = Path('.local-checks/Archives/EntrixyPersonal.xcarchive')
    if archive.exists():
        raise RuntimeError('Refusing to reuse a prior personal device archive')
    archive.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        'xcodebuild', '-project', 'EntrixyPersonal.xcodeproj', '-scheme', 'Entrixy',
        '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
        '-clonedSourcePackagesDirPath', '.local-checks/SourcePackages',
        '-derivedDataPath', '.local-checks/PersonalDeviceDerivedData', '-archivePath', str(archive),
        'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'archive',
    ], check=True, timeout=1800)
    app = archive / 'Products/Applications/Entrixy.app'
    subprocess.run(['python3', 'scripts/verify_release_isolation.py',
        '.local-checks/DerivedData/Build/Products/Debug-iphonesimulator/Entrixy.app', str(app)], check=True, timeout=120)
    output = Path('.local-checks/ci/iphone11/Entrixy-iPhone11.ipa')
    output.parent.mkdir(parents=True, exist_ok=True)
    record = package(app, output)
    sha = hashlib.sha256(output.read_bytes()).hexdigest()
    source = os.environ.get('GITHUB_SHA') or subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    report = dict(kind='iphone-personal-sideload-ipa', source_sha=source, bundle=record,
        sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-version'],text=True).strip(),
        filename=output.name, bytes=output.stat().st_size, sha256=sha,
        signed=False, requires_local_signing=True, signing_method='Sideloadly on Windows11 with own Apple Account',
        app_store_upload_ready=False, physical_device_tested=False,
        limitations=['APNs', 'Widget/App Groups', 'Associated Domains', 'Access Wi-Fi Information'],
        access_conditions_preserved=True)
    (output.parent / 'package.json').write_text(json.dumps(report, indent=2) + '\n')
    (output.parent / 'SHA256SUMS').write_text(sha + '  ' + output.name + '\n')
    shutil.copyfile('docs/IPHONE11_WINDOWS_INSTALL.md', output.parent / 'INSTALL-WINDOWS11.md')
    print('Prepared verified arm64 iPhone IPA for local signing:', output.name, sha, flush=True)


if __name__ == '__main__':
    main()
