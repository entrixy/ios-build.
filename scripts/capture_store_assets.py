#!/usr/bin/env python3
"""Capture original OS-renderer JPEGs; no resizing, compositing or image editing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
from capture_simulator import ROOT, BUNDLE, TEXT_TOOL, run, cleanup_device
from prepare_review_simulator import prepared_device

SCREENS = {
    'owner-control': ['Управление', 'Ворота во двор'],
    'owner-objects': ['Настройки', 'Объекты', 'Ворота во двор'],
    'owner-guests': ['Гости', 'Добавить гостя'],
    'sounds': ['Настройки', 'Звуки', 'Громкость звуков приложения'],
}


def verify_format(properties):
    if (properties.get('format') != 'jpeg' or properties.get('hasAlpha') != 'no'
            or properties.get('pixelWidth') != '1179' or properties.get('pixelHeight') != '2556'):
        raise ValueError('Original renderer image does not match the required JPEG/no-alpha/1179x2556 format')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared-device',type=Path,required=True)
    args = parser.parse_args()
    review = json.loads((ROOT/'.local-checks/ci/screenshots/review.json').read_text())
    if review.get('source_sha') != os.environ.get('GITHUB_SHA') or review.get('complete') is not True or review.get('tests_succeeded') is not True:
        raise RuntimeError('Store candidates require this source’s complete successful native/UI review')
    output = ROOT/'.local-checks/ci/store-assets/ru'
    if output.exists():
        raise RuntimeError('Refusing to reuse or mix an existing Store capture batch')
    output.mkdir(parents=True)
    run('xcrun', 'swiftc', str(ROOT/'scripts/verify_capture_text.swift'), '-o', str(TEXT_TOOL), timeout=120)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True,timeout=60).strip()
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json'],timeout=60))['runtimes']
    runtime = next(r['identifier'] for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier']
                   and (r['version'] == sdk or r['version'].startswith(sdk+'.')))
    device = prepared_device(args.prepared_device,runtime)
    container = Path(run('xcrun','simctl','get_app_container',device,BUNDLE,'data',timeout=60))
    captures = []
    try:
        run('xcrun','simctl','terminate',device,BUNDLE,optional=True)
        run('xcrun', 'simctl', 'ui', device, 'appearance', 'light',timeout=60)
        for index, (page, expected) in enumerate(SCREENS.items()):
            if index:
                run('xcrun', 'simctl', 'terminate', device, BUNDLE)
            status = container/'Library/Caches/stage-two-status.json'
            status.unlink(missing_ok=True)
            run('xcrun', 'simctl', 'launch', device, BUNDLE, '--stage-two', page,
                '-AppleLanguages', '(ru)', '-AppleLocale', 'ru_RU', '-entrixy.language', 'ru', timeout=180)
            deadline = time.monotonic()+180
            while not status.exists():
                if time.monotonic() > deadline:
                    raise RuntimeError('Native product route did not become ready: '+page)
                time.sleep(0.5)
            state = json.loads(status.read_text())
            if not (state.get('ready') is True and state.get('product_routes') is True
                    and state.get('route') == page and state.get('journal') == 0):
                raise RuntimeError('Unexpected native Store capture profile')
            image = output/(page+'.jpg')
            deadline = time.monotonic()+90
            while True:
                # JPEG is produced by simctl itself. No alpha removal or other
                # transformation is applied to the original renderer output.
                run('xcrun', 'simctl', 'io', device, 'screenshot', '--type=jpeg', str(image))
                check = subprocess.run([str(TEXT_TOOL), str(image), *expected], capture_output=True, text=True, timeout=60)
                if check.returncode == 0:
                    break
                if check.returncode != 1 or time.monotonic() > deadline:
                    raise RuntimeError('Visible native content was not verified: '+page)
                time.sleep(1)
            properties = {}
            result = subprocess.check_output(['sips', '-g', 'format', '-g', 'hasAlpha', '-g', 'pixelWidth', '-g', 'pixelHeight', str(image)], text=True,timeout=30)
            for line in result.splitlines()[1:]:
                key, separator, value = line.strip().partition(': ')
                if separator:
                    properties[key] = value
            verify_format(properties)
            captures.append(dict(screen=page,file='ru/'+image.name,language='ru',appearance='light',
                                 width=1179,height=2556,format='jpeg',has_alpha=False,
                                 sha256=hashlib.sha256(image.read_bytes()).hexdigest(),
                                 visible_text_verified=True,isolated_test_profile=state))
        (output.parent/'review.json').write_text(json.dumps(dict(
            kind='native-os-renderer-store-candidates',source_sha=os.environ['GITHUB_SHA'],
            runtime=runtime,captures=captures,complete=len(captures)==len(SCREENS),
            byte_transformations=[],visual_review='pending',app_store_uploaded=False,
            physical_device_tested=False,final_store_selection='pending'),ensure_ascii=False,indent=2)+'\n')
        print('Captured four original native JPEG candidates; visual review and final Store acceptance remain pending.')
    finally:
        cleanup_device(device)


if __name__ == '__main__':
    main()
