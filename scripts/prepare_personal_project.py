#!/usr/bin/env python3
"""Derive an app-only sideload project; never modify the Store spec or sign in."""
import copy
import json
from pathlib import Path
import yaml


def personal_spec(source):
    result = copy.deepcopy(source)
    result['name'] = 'EntrixyPersonal'
    targets = result['targets']
    app = targets['Entrixy']
    # Retain test targets so the same application can be checked on a simulator.
    targets.pop('EntrixyWidget')
    app['dependencies'] = [item for item in app['dependencies'] if item.get('target') != 'EntrixyWidget']
    base = app['settings']['base']
    # Simulator Keychain requires its existing ad-hoc application identifier.
    # Only physical-device entitlements are replaced for local personal signing.
    base['CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]'] = 'scripts/personal.entitlements'
    base['CODE_SIGN_STYLE'] = 'Automatic'
    properties = app['info']['properties']
    properties.pop('EntrixyAppGroup', None)
    properties.pop('EntrixyPushEnvironment', None)
    properties['EntrixyBuildVariant'] = 'personal'
    properties['UIBackgroundModes'] = [value for value in properties.get('UIBackgroundModes', []) if value != 'remote-notification']
    app['info']['path'] = '.local-checks/EntrixyPersonal-Info.plist'
    result['settings']['base']['ENTRIXY_APP_GROUP'] = ''
    return result


def main():
    root = Path(__file__).resolve().parent.parent
    source = yaml.safe_load((root / 'project.yml').read_text())
    result = personal_spec(source)
    output = root / 'project.personal.json'
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print('Prepared app-only personal-signing spec:', output.name, flush=True)


if __name__ == '__main__':
    main()
