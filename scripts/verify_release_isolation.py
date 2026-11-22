#!/usr/bin/env python3
"""Reject simulator fixture/bootstrap markers in the actual Release executable."""
import argparse
import plistlib
from pathlib import Path

MARKERS = [b'--capture-actions', b'preview-bootstrap.json', b'action-capture-status.json',
           b'com.entrixy.ios.capture.', b'controller.invalid', b'--native-design', b'native-design-status.json', b'--stage-two', b'stage-two-status.json', b'--ui-offline-promotions']


def verify_personal_integrations(bundle, *, debug=False):
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    plugins = bundle / 'PlugIns'
    # build-for-testing embeds the hosted XCTest bundle in the Debug app.
    # Distribution must contain neither test bundles nor app extensions.
    invalid_plugins = plugins.exists() and (not debug or any(
        item.name != 'EntrixyAppTests.xctest' or not item.is_dir()
        for item in plugins.iterdir()))
    if (invalid_plugins or info.get('EntrixyAppGroup') or info.get('EntrixyPushEnvironment')
            or 'remote-notification' in info.get('UIBackgroundModes', [])):
        raise RuntimeError('Personal application unexpectedly includes paid-profile integration')


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
        if info.get('EntrixyBuildVariant') == 'personal':
            verify_personal_integrations(bundle, debug=bundle == args.debug_app)
        else:
            widget_info = plistlib.loads((bundle / 'PlugIns/EntrixyWidget.appex/Info.plist').read_bytes())
            group = info.get('EntrixyAppGroup', '')
            if not group.startswith('group.') or '$' in group or widget_info.get('EntrixyAppGroup') != group:
                raise RuntimeError('App/widget do not have the same expanded App Group setting')
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
    personal = plistlib.loads((args.release_app / 'Info.plist').read_bytes()).get('EntrixyBuildVariant') == 'personal'
    if not personal:
        required_reasons(args.release_app / 'PlugIns/EntrixyWidget.appex', {
            'NSPrivacyAccessedAPICategoryFileTimestamp':['C617.1']})
    app_manifest = plistlib.loads((args.release_app / 'PrivacyInfo.xcprivacy').read_bytes())
    widget_manifest = {} if personal else plistlib.loads((args.release_app / 'PlugIns/EntrixyWidget.appex/PrivacyInfo.xcprivacy').read_bytes())
    if app_manifest.get('NSPrivacyTracking') is not False or (not personal and widget_manifest.get('NSPrivacyTracking') is not False):
        raise RuntimeError('Built privacy manifests do not match the audited no-tracking behavior')
    expected_types = {'EmailAddress','UserID','DeviceID','ProductInteraction','AdvertisingData',
                      'OtherUserContent','EmailsOrTextMessages','CrashData','OtherDiagnosticData'}
    rows = app_manifest.get('NSPrivacyCollectedDataTypes', [])
    declared_types = {row.get('NSPrivacyCollectedDataType') for row in rows}
    if len(rows) != len(expected_types) or declared_types != {'NSPrivacyCollectedDataType'+value for value in expected_types}:
        raise RuntimeError('Built app is missing audited data-flow declarations')
    allowed_purposes = {'NSPrivacyCollectedDataTypePurposeAppFunctionality',
                        'NSPrivacyCollectedDataTypePurposeDeveloperAdvertising',
                        'NSPrivacyCollectedDataTypePurposeAnalytics'}
    for row in rows:
        if (type(row.get('NSPrivacyCollectedDataTypeLinked')) is not bool
                or row.get('NSPrivacyCollectedDataTypeTracking') is not False
                or not row.get('NSPrivacyCollectedDataTypePurposes')
                or not set(row['NSPrivacyCollectedDataTypePurposes']).issubset(allowed_purposes)):
            raise RuntimeError('Built app has an incomplete audited data-flow declaration')
    if not personal and widget_manifest.get('NSPrivacyCollectedDataTypes') != []:
        raise RuntimeError('Widget must not declare a nonexistent server data collection path')
    print('Audited app data-flow declarations and on-device-only widget manifest are packaged')
    print('Required API manifests verified in the actual Release app and widget bundles')
    print('Release fixture/bootstrap isolation verified in built executable')


if __name__ == '__main__':
    main()
