#!/usr/bin/env python3
"""Opt-in, real offline downloads in an isolated iOS Simulator app.

Uses committed HEAD by default; --working-tree overlays Sources changes and additions.
No phone is targeted. Downloaded media remains in this QA app's private library.
Only episode numbers, byte counts, timing and safe error codes are recorded.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import time


def run(*args, **kwargs):
    kwargs.setdefault('timeout', 900)
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--episodes', nargs=2, type=int, default=[1, 91])
    parser.add_argument('--working-tree', action='store_true')
    parser.add_argument('--stop-on-failure', action='store_true')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    first, last = args.episodes
    if not 1 <= first <= last <= 91:
        parser.error('Episodes must be within 1–91.')
    root = Path(__file__).resolve().parents[1]
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j']))
    device = next((d for group in inventory['devices'].values() for d in group if d['udid'] == args.device), None)
    if not device or not device.get('isAvailable'):
        parser.error('An available iOS Simulator UUID is required.')
    output = Path(args.output).resolve(); output.mkdir(parents=True, exist_ok=False)
    source = output / 'source'; source.mkdir()
    archive = output / 'source.tar'
    run('git', '-C', str(root), 'archive', '--format=tar', '-o', str(archive), 'HEAD')
    with tarfile.open(archive) as tar:
        tar.extractall(source)  # Archive generated above from this repository only.
    if args.working_tree:
        changed = subprocess.check_output(['git', '-C', str(root), 'diff', '--name-only', '-z', 'HEAD', '--', 'Sources']).decode().split('\0')
        changed += subprocess.check_output(['git', '-C', str(root), 'ls-files', '--others', '--exclude-standard', '-z', '--', 'Sources']).decode().split('\0')
        for name in filter(None, changed):
            if (root / name).is_file():
                (source / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(root / name, source / name)
            elif (source / name).exists(): (source / name).unlink()
        patch = subprocess.check_output(['git', '-C', str(root), 'diff', 'HEAD', '--', 'Sources'])
        (output / 'source-overlay.patch').write_bytes(patch)
    shutil.copy2(root / 'Tests/OfflineDownloadSimulator/HongguoApp.swift', source / 'iOS/Hongguo/App/HongguoApp.swift')
    # Safe observability only: do not change the actual resolution decisions.
    catalog = source / 'Sources/HongguoCore/NativeCatalogService.swift'
    code = catalog.read_text()
    marker = '                guard let resolvePlayable else { throw error }'
    assert code.count(marker) == 1
    log = '                FileHandle.standardOutput.write(Data(("OFFLINE_BATCH_QA RECOVERY episode=\\(episode.number) code=\\((error as? NativeSourceError)?.code ?? "NETWORK")\\n").utf8))\n'
    code = code.replace(marker, marker + '\n' + log)
    marker = '                    try await sourceRetryDelay(cooldowns[attempt])'
    if marker in code:
        code = code.replace(marker, '                    FileHandle.standardOutput.write(Data(("OFFLINE_BATCH_QA COOLDOWN episode=\\(episode.number) attempt=\\(attempt + 1)\\n").utf8))\n' + marker)
    marker = '                    try await Task.sleep(for: .seconds(1))'
    if marker in code:
        assert code.count(marker) == 1
        log = '                    FileHandle.standardOutput.write(Data(("OFFLINE_BATCH_QA RETRY episode=\\(episode.number) code=\\((error as? NativeSourceError)?.code ?? "NETWORK")\\n").utf8))\n'
        code = code.replace(marker, log + marker)
    catalog.write_text(code)
    http = source / 'Sources/HongguoCore/NativeRuntime/NativeHTTP.swift'
    code = http.read_text()
    marker = '            let (data, response) = try await NativeHTTPTransaction().run(request)'
    assert code.count(marker) == 1
    code = code.replace(marker, marker + '\n' + '''            if request.url?.path.contains("/service/2/device_register") == true {
                FileHandle.standardOutput.write(Data(("OFFLINE_BATCH_QA REGISTER status=\\(response.statusCode) bytes=\\(data.count)\\n").utf8))
            }''')
    http.write_text(code)
    (output / 'source-commit.txt').write_bytes(subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD']))
    bundle = 'tw.mountainp.hongguo.offlinebatchqa'
    with (output / 'build.log').open('w') as log:
        run('xcodebuild', '-project', str(source / 'iOS/Hongguo.xcodeproj'), '-scheme', 'Hongguo',
            '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator',
            '-derivedDataPath', str(output / 'DerivedData'), '-jobs', '2', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
            'CODE_SIGNING_ALLOWED=NO', 'PRODUCT_BUNDLE_IDENTIFIER=' + bundle, 'build', stdout=log, stderr=log)
    app = output / 'DerivedData/Build/Products/Debug-iphonesimulator/Hongguo.app'
    run('codesign', '--force', '--deep', '--sign', '-', str(app))
    run('codesign', '--verify', '--deep', '--strict', str(app))
    booted_here = device['state'] != 'Booted'

    def phase(name, options, timeout):
        stdout, stderr = output / (name + '.stdout'), output / (name + '.stderr')
        run('xcrun', 'simctl', 'launch', '--terminate-running-process', '--stdout=' + str(stdout),
            '--stderr=' + str(stderr), args.device, bundle, *options, timeout=45)
        deadline, printed = time.monotonic() + timeout, 0
        while time.monotonic() < deadline:
            result = stdout.read_text(errors='replace') if stdout.exists() else ''
            if len(result) > printed:
                print(result[printed:], end='', flush=True); printed = len(result)
            if 'OFFLINE_BATCH_QA FAIL ' in result: raise RuntimeError(name + ' failed')
            if 'OFFLINE_BATCH_QA RESULT ' in result: return result
            time.sleep(1)
        raise TimeoutError(name)

    try:
        if booted_here: run('xcrun', 'simctl', 'boot', args.device, timeout=60)
        run('xcrun', 'simctl', 'bootstatus', args.device, '-b', timeout=120)
        # Only reset the dedicated QA bundle, never the user's simulator app.
        subprocess.run(['xcrun', 'simctl', 'uninstall', args.device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=45)
        run('xcrun', 'simctl', 'install', args.device, str(app), timeout=90)
        options = [f'qa-episodes={first},{last}']
        if args.stop_on_failure: options.append('qa-stop-on-failure')
        result = phase('download', options, 7250)
        if 'baseline_failed' in result: return 1
        if 'failed=0 ' not in result: return 1
        # Relaunch proves persistence and decodes only verified local file URLs.
        phase('reopen', ['qa-reopen'], 900)
        print('Evidence:', output)
        return 0
    finally:
        try:
            subprocess.run(['xcrun', 'simctl', 'terminate', args.device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        finally:
            if booted_here: run('xcrun', 'simctl', 'shutdown', args.device, timeout=60)


if __name__ == '__main__':
    raise SystemExit(main())
