#!/usr/bin/env python3
"""Prepare an AASA file locally; never writes the live website or publishes it."""
import argparse
import json
from pathlib import Path
import re


def association(prefix, bundle):
    # The application identifier prefix comes from the actual provisioning
    # account/profile; do not guess that a legacy prefix equals the Team ID.
    if not re.fullmatch(r'[A-Z0-9]{10}', prefix):
        raise ValueError('A confirmed ten-character application identifier prefix is required')
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
        raise ValueError('A confirmed bundle identifier is required')
    paths = ['/key', '/key/', '/i/*', '/c/*', '/o/*', '/claim', '/claim/']
    return {'applinks': {'details': [{'appIDs': [prefix + '.' + bundle],
                                     'components': [{'/': path} for path in paths]}]}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--application-identifier-prefix', required=True)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--output', type=Path, default=Path('.local-checks/AppStore/association'))
    args = parser.parse_args()
    value = association(args.application_identifier_prefix, args.bundle_id)
    target = args.output
    if target.exists():
        raise ValueError('Choose a fresh output directory; existing release material is preserved')
    target.mkdir(parents=True)
    (target / 'apple-app-site-association').write_text(json.dumps(value, indent=2) + '\n')
    (target / 'readiness.json').write_text(json.dumps({
        'domain': 'entrixy.com', 'published': False, 'device_verified': False,
        'required_url': 'https://entrixy.com/.well-known/apple-app-site-association',
        'requires': ['matching signed app/profile entitlement', 'HTTPS JSON without redirects',
                     'Apple CDN/device verification after publication']}, indent=2) + '\n')
    print('Prepared local association file; website publication and device verification remain pending')


if __name__ == '__main__':
    main()
