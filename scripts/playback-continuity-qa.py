#!/usr/bin/env python3
"""Run the production player in an isolated simulator app; never target an iPhone.

Archives committed HEAD, injects only the QA entry point and fault fixtures,
then plays Qingmei at 2x or exercises a synthetic failure. Requires Xcode and,
for synthetic cases, ffmpeg with libx264. Evidence stays in ignored build/.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='Dedicated iOS Simulator UUID')
    parser.add_argument('--case', choices=['live', 'terminal', 'stalled', 'smooth', 'cancel'], default='live')
    parser.add_argument('--episodes', nargs=2, type=int, default=[20, 29])
    parser.add_argument('--quality', choices=['automatic', 'smooth', 'dataSaver'], default='automatic')
    parser.add_argument('--ffmpeg', default=shutil.which('ffmpeg'))
    args = parser.parse_args()
    if not 1 <= args.episodes[0] <= args.episodes[1] <= 91:
        parser.error('Episodes must be within 1–91.')
    if args.case != 'live' and not args.ffmpeg:
        parser.error('Synthetic cases require --ffmpeg /path/to/ffmpeg.')
    root = Path(__file__).resolve().parents[1]
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j']))
    devices = [device for group in inventory['devices'].values() for device in group]
    device = next((item for item in devices if item['udid'] == args.device), None)
    if not device or not device.get('isAvailable'):
        parser.error('The device must be an available iOS Simulator.')
    output = root / 'build' / ('continuity-qa-' + time.strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True)
    source = output / 'source'; source.mkdir()
    archive = output / 'source.tar'
    run('git', '-C', str(root), 'archive', '--format=tar', '-o', str(archive), 'HEAD')
    with tarfile.open(archive) as tar:
        tar.extractall(source)  # Local, committed Git tree only.
    fixtures = source / 'Tests/PlaybackContinuitySimulator'
    shutil.copy2(fixtures / 'HongguoApp.swift', source / 'iOS/Hongguo/App/HongguoApp.swift')
    shutil.copy2(fixtures / 'ContinuitySimulatorFixture.swift', source / 'Sources/HongguoCore/ContinuitySimulatorFixture.swift')
    bundle = 'tw.mountainp.hongguo.bufferqa'
    with (output / 'build.log').open('w') as log:
        run('xcodebuild', '-project', str(source / 'iOS/Hongguo.xcodeproj'), '-scheme', 'Hongguo',
            '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator',
            '-derivedDataPath', str(output / 'DerivedData'), '-jobs', '2', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
            'CODE_SIGNING_ALLOWED=NO', 'PRODUCT_BUNDLE_IDENTIFIER=' + bundle, 'build', stdout=log, stderr=log)
    app = output / 'DerivedData/Build/Products/Debug-iphonesimulator/Hongguo.app'
    run('codesign', '--force', '--deep', '--sign', '-', str(app))
    booted_here = device['state'] != 'Booted'
    if booted_here:
        run('xcrun', 'simctl', 'boot', args.device)
    try:
        run('xcrun', 'simctl', 'bootstatus', args.device, '-b')
        run('xcrun', 'simctl', 'install', args.device, str(app))
        if args.case != 'live':
            documents = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.device, bundle, 'data'], text=True).strip()) / 'Documents'
            documents.mkdir(exist_ok=True)
            with (output / 'fixture-encoding.log').open('w') as log:
                for name, size, bitrate in [('fixture.mp4', '320x180', '1000k'), ('fixture-low.mp4', '160x90', '100k')]:
                    run(args.ffmpeg, '-y', '-f', 'lavfi', '-i', f'testsrc2=size={size}:rate=10:duration=60',
                        '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', bitrate, '-minrate', bitrate,
                        '-maxrate', bitrate, '-bufsize', '2000k', '-x264-params', 'nal-hrd=cbr', '-movflags', '+faststart',
                        str(documents / name), stdout=log, stderr=log)
        first, last = args.episodes if args.case == 'live' else (20, 20)
        options = [f'qa={first},{last},2', '-playback-health-diagnostics', '-playback-buffer-diagnostics']
        if args.case != 'live': options.append('qa-fixture=' + args.case)
        quality = 'smooth' if args.case == 'smooth' else args.quality
        if quality == 'smooth': options.append('qa-smooth')
        if quality == 'dataSaver': options.append('qa-data-saver')
        stdout, stderr = output / 'playback.stdout', output / 'playback.stderr'
        run('xcrun', 'simctl', 'launch', '--terminate-running-process', '--stdout=' + str(stdout),
            '--stderr=' + str(stderr), args.device, bundle, *options)
        deadline = time.monotonic() + max(150, (last-first+1) * 100)
        while time.monotonic() < deadline:
            result = stdout.read_text(errors='replace') if stdout.exists() else ''
            if 'SIMULATOR_QA FAIL' in result or 'SIMULATOR_QA RESULT' in result:
                print(result)
                print('Evidence:', output)
                return 1 if 'SIMULATOR_QA FAIL' in result else 0
            time.sleep(0.25)
        print('Timed out. Evidence:', output)
        return 2
    finally:
        subprocess.run(['xcrun', 'simctl', 'terminate', args.device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if booted_here:
            run('xcrun', 'simctl', 'shutdown', args.device)


if __name__ == '__main__':
    raise SystemExit(main())
