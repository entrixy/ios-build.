#!/usr/bin/env python3
"""Build/inspect an unsigned iPhone Release archive; never export or upload an IPA."""
import json
import hashlib
import os
from pathlib import Path
import plistlib
import struct
import subprocess


def verify_device_image(data):
    # A simulator on Apple Silicon is also arm64: the CPU alone proves nothing.
    if len(data) < 32:
        raise ValueError('Truncated Mach-O header')
    magic, cpu, _, _, count, size, _, _ = struct.unpack('<IiiIIIII', data[:32])
    if magic != 0xFEEDFACF or cpu != 0x0100000C or not (1 <= count <= 4096) or size > len(data)-32:
        raise ValueError('Expected a thin arm64 Release executable')
    offset, end, platforms = 32, 32+size, []
    for _ in range(count):
        if offset+8 > end:
            raise ValueError('Truncated Mach-O load command')
        command, length = struct.unpack('<II', data[offset:offset+8])
        if length < 8 or offset+length > end:
            raise ValueError('Invalid Mach-O load command length')
        if command == 0x32:  # LC_BUILD_VERSION
            if length < 24:
                raise ValueError('Truncated Mach-O build version')
            platforms.append(struct.unpack('<I', data[offset+8:offset+12])[0])
        offset += length
    if offset != end or platforms != [2]:  # PLATFORM_IOS=2, IOSSIMULATOR=7
        raise ValueError('Executable does not target the physical iOS platform')


def bundle_record(bundle):
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    if info.get('DTPlatformName') != 'iphoneos' or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Archive contains a simulator or non-iPhone bundle')
    verify_device_image((bundle / info['CFBundleExecutable']).read_bytes())
    if (bundle / 'embedded.mobileprovision').exists() or (bundle / '_CodeSignature').exists():
        raise ValueError('This CI archive must stay unsigned and contain no provisioning profile')
    if not (bundle / 'PrivacyInfo.xcprivacy').is_file():
        raise ValueError('Device Release bundle has no privacy manifest')
    return dict(bundle_id=info['CFBundleIdentifier'], version=info['CFBundleShortVersionString'],
                build=info['CFBundleVersion'], minimum_ios=info['MinimumOSVersion'],
                architecture='arm64', platform='iphoneos', signed=False)


def main():
    archive = Path('.local-checks/Archives/Entrixy.xcarchive')
    if archive.exists():
        raise RuntimeError('Refusing to reuse an existing device archive')
    archive.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        'xcodebuild', '-project', 'Entrixy.xcodeproj', '-scheme', 'Entrixy',
        '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
        '-derivedDataPath', '.local-checks/DeviceDerivedData', '-archivePath', str(archive),
        'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'archive',
    ], check=True, timeout=1800)
    app = archive / 'Products/Applications/Entrixy.app'
    widget = app / 'PlugIns/EntrixyWidget.appex'
    records = dict(app=bundle_record(app), widget=bundle_record(widget))
    camera_framework = app / 'Frameworks/VLCKit.framework'
    camera_info = plistlib.loads((camera_framework / 'Info.plist').read_bytes())
    camera_binary = (camera_framework / camera_info['CFBundleExecutable']).read_bytes()
    verify_device_image(camera_binary)
    if struct.unpack('<I', camera_binary[12:16])[0] != 6:
        raise ValueError('Camera library must remain a dynamically linked framework')
    if not (app / 'VLCKit-LICENSE.txt').is_file():
        raise ValueError('Camera library license/source-access notice is missing')
    if (widget / 'Frameworks/VLCKit.framework').exists():
        raise ValueError('The camera decoder must not be embedded in the widget')
    if any(path.name.startswith(('camera-decoder.', 'dash-init-', 'dash-seg-')) for path in app.rglob('*')):
        raise ValueError('Unit-test camera media must not be packaged in the Release app')
    camera = dict(bundle_id=camera_info['CFBundleIdentifier'], platform='iphoneos',
                  architectures=['arm64'], dynamically_linked=True,
                  sha256=hashlib.sha256(camera_binary).hexdigest(), license_packaged=True)
    if not records['widget']['bundle_id'].startswith(records['app']['bundle_id'] + '.'):
        raise ValueError('Widget bundle identifier does not belong to the archived application')
    subprocess.run([
        'python3', 'scripts/verify_release_isolation.py',
        '.local-checks/DerivedData/Build/Products/Debug-iphonesimulator/Entrixy.app', str(app),
    ], check=True, timeout=120)
    output = Path('.local-checks/ci/device-release.json')
    output.parent.mkdir(parents=True, exist_ok=True)
    source = os.environ.get('GITHUB_SHA') or subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    report = dict(kind='unsigned-iphone-release-archive', source_sha=source,
                  sdk=subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip(),
                  bundles=records, camera_framework=camera, fixture_isolation='passed', privacy_manifest_packaging='passed',
                  upload_ready=False, signing_and_provisioning='pending', physical_device_tested=False)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print('Built/verified unsigned iPhone Release app and widget. Signing, device testing and App Store upload remain pending.', flush=True)


if __name__ == '__main__':
    main()
