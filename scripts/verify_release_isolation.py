#!/usr/bin/env python3
"""Reject simulator fixture/bootstrap markers in the actual Release executable."""
import argparse
import plistlib
from pathlib import Path

MARKERS = [b'--capture-actions', b'preview-bootstrap.json', b'action-capture-status.json',
           b'com.entrixy.ios.capture.', b'controller.invalid', b'--native-design', b'native-design-status.json', b'--stage-two', b'stage-two-status.json', b'--ui-offline-promotions']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('debug_app', type=Path)
    parser.add_argument('release_app', type=Path)
    args = parser.parse_args()
    def image_bytes(app):
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        executable = app / info['CFBundleExecutable']
        # Xcode may put Debug Swift code in Entrixy.debug.dylib behind a small stub.
        return b''.join(path.read_bytes() for path in [executable, *app.glob('*.dylib')])
    debug = image_bytes(args.debug_app)
    release = image_bytes(args.release_app)
    if MARKERS[0] not in debug:
        raise RuntimeError('Debug executable does not contain the expected capture entry point')
    if any(marker in release for marker in MARKERS):
        raise RuntimeError('Release executable contains isolated fixture/bootstrap code')
    for bundle, environment in [(args.debug_app, 'sandbox'), (args.release_app, 'production')]:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        if info.get('EntrixyPushEnvironment') != environment or 'remote-notification' not in info.get('UIBackgroundModes', []):
            raise RuntimeError('Built application has an incorrect APNs environment/background declaration')
        for language in ['en','ru','de','es','fr','pt','zh']:
            if not (bundle / (language + '.lproj') / 'Localizable.strings').is_file():
                raise RuntimeError('Built application is missing a localized OS message alert: ' + language)
    def required_reasons(bundle, expected):
        manifest = plistlib.loads((bundle / 'PrivacyInfo.xcprivacy').read_bytes())
        declared = {row['NSPrivacyAccessedAPIType']:set(row['NSPrivacyAccessedAPITypeReasons'])
                    for row in manifest.get('NSPrivacyAccessedAPITypes', [])}
        for category, reasons in expected.items():
            if not set(reasons).issubset(declared.get(category,set())):
                raise RuntimeError('Built bundle is missing required API reasons: ' + category)
    required_reasons(args.release_app, {
        'NSPrivacyAccessedAPICategoryUserDefaults':['CA92.1'],
        'NSPrivacyAccessedAPICategorySystemBootTime':['35F9.1'],
        'NSPrivacyAccessedAPICategoryFileTimestamp':['C617.1','3B52.1']})
    required_reasons(args.release_app / 'PlugIns/EntrixyWidget.appex', {
        'NSPrivacyAccessedAPICategoryFileTimestamp':['C617.1']})
    print('Required API manifests verified in the actual Release app and widget bundles')
    print('Release fixture/bootstrap isolation verified in built executable')


if __name__ == '__main__':
    main()
