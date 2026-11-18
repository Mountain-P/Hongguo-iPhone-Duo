#!/usr/bin/env python3
"""Exercise the real home relay through the production player on a simulator only.
Private --config JSON: baseURL, token, seriesID. Never commit it or print its contents.
Snapshot includes uncommitted nonignored source; SHA256 manifest identifies exactly what ran.
"""
import argparse, hashlib, json, os, shutil, subprocess, time
from pathlib import Path

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--device', required=True)
    p.add_argument('--config', type=Path, required=True)
    p.add_argument('--case', choices=['live','controls','offline','offline-reopen'], default='live')
    p.add_argument('--episodes', nargs=2, type=int, default=[1,3])
    p.add_argument('--reuse', type=Path, help='Reuse a previously compiled evidence directory')
    p.add_argument('--reset-unsupported', action='store_true', help='Remove failed unsupported records in this isolated QA library before enqueue')
    p.add_argument('--rebuild', action='store_true')
    p.add_argument('--keep-booted', action='store_true')
    args = p.parse_args()
    root = Path(__file__).resolve().parents[1]
    devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','-j']))['devices']
    device = next((d for group in devices.values() for d in group if d['udid']==args.device and d.get('isAvailable')),None)
    if not device: p.error('An available iOS Simulator UUID is required.')
    output = args.reuse.resolve() if args.reuse else root/'build'/('home-relay-qa-'+time.strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True,exist_ok=True)
    bundle = 'tw.mountainp.hongguo.relayqa'
    if not args.reuse or args.rebuild:
        source = output/'source'; source.mkdir(exist_ok=True)
        files = subprocess.check_output(['git','ls-files','-co','--exclude-standard','-z'],cwd=root).decode().split('\0')
        manifest = {}
        for name in sorted(set(filter(None,files))):
            origin=root/name
            if not origin.is_file(): continue
            target=source/name; target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(origin,target); manifest[name]=hashlib.sha256(origin.read_bytes()).hexdigest()
        (output/'source-sha256.json').write_text(json.dumps(manifest,indent=2))
        shutil.copy2(source/'Tests/HomeRelaySimulator/HongguoApp.swift',source/'iOS/Hongguo/App/HongguoApp.swift')
        with (output/'build.log').open('w') as log:
            run('xcodebuild','-project',str(source/'iOS/Hongguo.xcodeproj'),'-scheme','Hongguo','-configuration','Debug',
                '-sdk','iphonesimulator','-destination','generic/platform=iOS Simulator','-derivedDataPath',str(output/'DerivedData'),
                '-jobs','2','ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-','PRODUCT_BUNDLE_IDENTIFIER='+bundle,
                'build',stdout=log,stderr=log)
    app=output/'DerivedData/Build/Products/Debug-iphonesimulator/Hongguo.app'
    if device['state'] != 'Booted': run('xcrun','simctl','boot',args.device)
    try:
        run('xcrun','simctl','bootstatus',args.device,'-b')
        run('xcrun','simctl','install',args.device,str(app))
        container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.device,bundle,'data'],text=True).strip())
        config=container/'Documents/relay-config.json'; config.parent.mkdir(exist_ok=True)
        shutil.copyfile(args.config,config); config.chmod(0o600)
        prefix=args.case+'-'+time.strftime('%H%M%S'); stdout=output/(prefix+'.stdout'); stderr=output/(prefix+'.stderr')
        first,last=args.episodes
        options=[f'qa={first},{last},2','-playback-health-diagnostics','-playback-buffer-diagnostics']
        if args.case!='live': options+=['qa-'+args.case]
        if args.reset_unsupported: options+=['qa-reset-unsupported']
        run('xcrun','simctl','launch','--terminate-running-process','--stdout='+str(stdout),'--stderr='+str(stderr),args.device,bundle,*options)
        print('Evidence:',output,flush=True)
        deadline=time.monotonic()+max(180,(last-first+1)*110)
        while time.monotonic()<deadline:
            result=stdout.read_text(errors='replace') if stdout.exists() else ''
            if 'RELAY_QA FAIL' in result or 'RELAY_QA RESULT' in result:
                print('\n'.join(line for line in result.splitlines() if line.startswith('RELAY_QA ')))
                return 1 if 'RELAY_QA FAIL' in result else 0
            time.sleep(.5)
        print('Timed out:',stdout); return 2
    finally:
        subprocess.run(['xcrun','simctl','terminate',args.device,bundle],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if not args.keep_booted: run('xcrun','simctl','shutdown',args.device)
if __name__=='__main__': raise SystemExit(main())
