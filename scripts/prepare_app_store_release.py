#!/usr/bin/env python3
"""Prepare confirmed signing settings/AASA locally. Never sign, publish or upload."""
import argparse
import json
from pathlib import Path
import re
from prepare_site_association import association


def prepare(inputs, output):
    if not isinstance(inputs, dict) or set(inputs) != {
        'confirmed', 'team_id', 'application_identifier_prefix', 'bundle_id', 'app_group'
    } or inputs.get('confirmed') is not True:
        raise ValueError('Provide exactly the five documented fields and confirm the registered identifiers')
    team, prefix, bundle, group = (inputs.get(k) for k in (
        'team_id', 'application_identifier_prefix', 'bundle_id', 'app_group'))
    identifier = r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+'
    if not all(isinstance(v, str) for v in (team, prefix, bundle, group)):
        raise ValueError('Registered identifiers are missing')
    if not re.fullmatch(r'[A-Z0-9]{10}', team) or not re.fullmatch(r'[A-Z0-9]{10}', prefix):
        raise ValueError('Team ID and application identifier prefix must each have ten uppercase letters/digits')
    if not re.fullmatch(identifier, bundle) or len(bundle) > 240 or bundle.startswith('group.'):
        raise ValueError('Invalid application bundle identifier')
    if not group.startswith('group.') or not re.fullmatch(identifier, group[6:]) or len(group) > 255:
        raise ValueError('Invalid registered App Group identifier')
    aasa = association(prefix, bundle)
    output = Path(output)
    if output.exists():
        raise ValueError('Choose a fresh output directory; existing release material is preserved')
    settings = '\n'.join([
        '// Registered identifiers only. No private key or provisioning profile belongs here.',
        'DEVELOPMENT_TEAM = ' + team,
        'ENTRIXY_APP_BUNDLE_ID = ' + bundle,
        'ENTRIXY_APP_GROUP = ' + group,
        'CODE_SIGN_STYLE = Automatic', '',
    ])
    output.mkdir(parents=True)
    (output / 'Signing.xcconfig').write_text(settings)
    (output / 'apple-app-site-association').write_text(json.dumps(aasa, indent=2) + '\n')
    report = {
        'kind': 'prepared-release-identifiers', 'bundle_id': bundle,
        'widget_bundle_id': bundle + '.widget', 'app_group': group,
        'signed': False, 'uploaded': False, 'association_published': False,
        'required_capabilities': ['Push Notifications', 'Associated Domains', 'Access Wi-Fi Information', 'App Groups'],
        'pending': ['Apple account capability/provisioning verification', 'actual signed archive and profile inspection',
                    'AASA HTTPS/CDN/device verification', 'APNs provider configuration and actual delivery',
                    'iPhone/Android/controller acceptance', 'privacy/export compliance and reviewer material'],
    }
    (output / 'readiness.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=Path('.local-checks/AppStore/registered-release'))
    args = parser.parse_args()
    if args.inputs.stat().st_size > 16384:
        parser.error('Release identifier input is too large; do not include credentials')
    try:
        prepare(json.loads(args.inputs.read_text()), args.output)
    except (ValueError, TypeError):
        parser.error('Invalid/unconfirmed identifiers or existing output; use the documented five-field format and a fresh output directory')
    print('Prepared local signing settings and AASA. Nothing signed, published or uploaded.')


if __name__ == '__main__':
    main()
