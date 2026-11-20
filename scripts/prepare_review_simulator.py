#!/usr/bin/env python3
"""Prepare and retain one healthy, job-owned simulator BEFORE compiling the app."""
import argparse
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import uuid
from capture_simulator import create_booted_device, cleanup_device, run


def source_sha():
    return os.environ.get('GITHUB_SHA') or subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()


def prepared_device(path, runtime, *, check_ui=True, missing_ok=False):
    report = json.loads(Path(path).read_text())
    if report.get('source_sha') != source_sha() or report.get('runtime') != runtime:
        raise RuntimeError('Prepared simulator does not belong to this source/runtime')
    device = report['device']; uuid.UUID(device)
    devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','--json'],text=True))['devices']
    owned = next((row for row in devices.get(runtime,[]) if row['udid'] == device),None)
    if owned is None and missing_ok:
        return None
    if not owned or not owned['name'].startswith('Entrixy preview ') or owned.get('deviceTypeIdentifier') != 'com.apple.CoreSimulator.SimDeviceType.iPhone-16':
        raise RuntimeError('Refusing to use or remove an unowned simulator')
    if check_ui:
        if owned['state'] != 'Booted':
            raise RuntimeError('Prepared simulator is no longer booted')
        run('xcrun','simctl','ui',device,'appearance','light',timeout=60)
    return device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=Path('.local-checks/ci/prepared-device.json'))
    parser.add_argument('--cleanup',action='store_true')
    args = parser.parse_args()
    if args.cleanup:
        if args.output.exists():
            report = json.loads(args.output.read_text())
            device = prepared_device(args.output,report['runtime'],check_ui=False,missing_ok=True)
            if device:
                cleanup_device(device)
        return
    if args.output.exists():
        raise RuntimeError('Do not overwrite or mix prepared simulator evidence')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-version'],text=True).strip()
    runtimes = json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','--json'],text=True))
    (args.output.parent/'simulator-runtimes.json').write_text(json.dumps(runtimes,indent=2)+'\n')
    runtime = next(r['identifier'] for r in runtimes['runtimes'] if r.get('isAvailable') and '.iOS-' in r['identifier'] and (r['version'] == sdk or r['version'].startswith(sdk+'.')))
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        # The disposable runner owns every device here; never do this on a
        # developer's Mac. Finish migrations before compiler memory pressure.
        run('xcrun','simctl','shutdown','all',timeout=30,optional=True)
    device = create_booted_device('isolated review','com.apple.CoreSimulator.SimDeviceType.iPhone-16',runtime,appearance='light')
    try:
        frame = args.output.parent/'simulator-preflight.png'
        run('xcrun','simctl','io',device,'screenshot','--type=png',str(frame),timeout=30)
        data = frame.read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n' or len(data) < 29:
            raise RuntimeError('Simulator UI did not produce a native frame')
        width,height = struct.unpack('>II',data[16:24])
        if min(width,height) <= 0:
            raise RuntimeError('Empty simulator frame')
        report = dict(kind='simulator-health-only',source_sha=source_sha(),runtime=runtime,sdk=sdk,
                      architecture=platform.machine(),device=device,width=width,height=height,
                      product_screenshot=False,app_scenarios_started=False)
        args.output.write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report),flush=True)
    except BaseException:
        cleanup_device(device)
        raise


if __name__ == '__main__':
    main()
