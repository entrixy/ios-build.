#!/usr/bin/env python3
"""Reuse the full Android client's product wording; do not independently rewrite UI labels."""
import argparse
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


def strings(path):
    values = {}
    for node in ET.parse(path).getroot().findall('string'):
        value = ''.join(node.itertext())
        # One Android escape pass: \\n is literal backslash+n, not a
        # backslash followed by a newline after two independent replacements.
        escapes = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"'}
        value = re.sub(r"\\(u[0-9a-fA-F]{4}|.)", lambda m:
            chr(int(m[1][1:], 16)) if m[1].startswith("u") and len(m[1]) == 5 else escapes.get(m[1], m[1]), value)
        value = re.sub(r'%(\d+\$)?s', lambda m: '%' + (m[1] or '') + '@', value)
        values[node.attrib['name']] = value
    return values


def main():
    p = argparse.ArgumentParser(); p.add_argument('android_root', type=Path)
    p.add_argument('--check', action='store_true'); args = p.parse_args()
    source = args.android_root / 'app/src/main/res'
    output = Path(__file__).resolve().parents[1] / 'App/Resources'
    base = strings(source / 'values/strings.xml')
    for language in ['en', 'ru', 'de', 'es', 'fr', 'pt', 'zh']:
        values = dict(base)
        if language != 'en': values.update(strings(source / ('values-' + language) / 'strings.xml'))
        content = '// Product wording imported from the full Android client.\n' + ''.join(
            json.dumps(key, ensure_ascii=False) + ' = ' + json.dumps(value, ensure_ascii=False) + ';\n'
            for key, value in sorted(values.items()))
        path = output / (language + '.lproj') / 'Product.strings'
        if args.check:
            assert path.read_text() == content, str(path)
        else:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text(content)
        print(language, len(values))


if __name__ == '__main__': main()
