#!/usr/bin/env python3
"""Reject simulator fixture/bootstrap markers in the actual Release executable."""
import argparse
import plistlib
from pathlib import Path

MARKERS = [b'--capture-actions', b'preview-bootstrap.json', b'action-capture-status.json',
           b'com.entrixy.ios.capture.', b'controller.invalid', b'--native-design', b'native-design-status.json']


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
    print('Release fixture/bootstrap isolation verified in built executable')


if __name__ == '__main__':
    main()
