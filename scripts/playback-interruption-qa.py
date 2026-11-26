#!/usr/bin/env python3
"""Run two real episodes on a Duo simulator with a six-second interruption on the selected media path."""
import argparse
import hashlib
import http.client
import http.server
import importlib.util
import json
from pathlib import Path
import shutil
import socket
import signal
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'tw.mountainp.hongguo.interruptionqa'


def run(*cmd, **kwargs):
    return subprocess.run(cmd, check=True, **kwargs)


def build(output):
    source = output / 'source'
    files = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    manifest = {}
    for name in sorted(set(filter(None, files))):
        origin = ROOT / name
        if not origin.is_file():
            continue
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(origin, target)
        manifest[name] = hashlib.sha256(origin.read_bytes()).hexdigest()
    (output / 'source-sha256.json').write_text(json.dumps(manifest, indent=2))
    fixtures = source / 'Tests/PlaybackInterruptionSimulator'
    shutil.copy2(fixtures / 'HongguoApp.swift', source / 'iOS/Hongguo/App/HongguoApp.swift')
    core = source / 'Sources/HongguoCore'
    for name in ('RangeInterruption.swift', 'LocalDirectFixture.swift'):
        shutil.copy2(fixtures / name, core / name)
    wire = core / 'NativeRangeHTTP.swift'
    original = wire.read_text()
    anchor = '        transfer.data.append(data)'
    if original.count(anchor) != 1:
        raise RuntimeError('Native range callback changed; review simulator fault insertion.')
    wire.write_text(original.replace(anchor, '        if RangeInterruption.interrupt(dataTask, incoming: data.count) { return }\n' + anchor))
    with (output / 'build.log').open('w') as log:
        run('xcodebuild','-project',str(source / 'iOS/Hongguo.xcodeproj'),'-scheme','Hongguo','-configuration','Debug',
            '-sdk','iphonesimulator','-destination','generic/platform=iOS Simulator','-derivedDataPath',str(output/'DerivedData'),
            '-jobs','4','ARCHS=arm64','CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-','PRODUCT_BUNDLE_IDENTIFIER='+BUNDLE,
            'build',stdout=log,stderr=log)


class RelayFaultProxy(http.server.ThreadingHTTPServer):
    """Only a caller-selected home relay is reachable. Interrupt its media socket after the simulator renders frames."""
    daemon_threads = True

    def __init__(self, upstream, marker):
        self.upstream = urllib.parse.urlsplit(upstream)
        if (self.upstream.scheme != 'https' and not (self.upstream.scheme == 'http' and self.upstream.hostname == '127.0.0.1')) or self.upstream.username or self.upstream.password:
            raise ValueError('Expected private HTTPS relay or an SSH loopback forward')
        self.marker = marker
        self.interrupted = threading.Event()
        self.resumed = threading.Event()
        self.lock = threading.Lock()
        self.dropped_paths = set()
        self.first_play_path = None
        self.prefetch_failed = False
        self.prefetch_retried = False
        self.inject_prefetch = False
        super().__init__(('127.0.0.1', 0), RelayHandler)

    def in_outage(self):
        try:
            return time.time() < float(self.marker.read_text())
        except (OSError, ValueError):
            return False


class RelayHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.forward()

    def do_HEAD(self):
        self.forward()

    def forward(self):
        proxy = self.server
        endpoint = urllib.parse.urlsplit(self.path)
        if endpoint.scheme or endpoint.netloc or not (endpoint.path == '/health' or endpoint.path.startswith('/api/')):
            self.send_error(404)
            return
        if proxy.inject_prefetch and endpoint.path.startswith('/api/episodes/') and endpoint.path.endswith('/play'):
            with proxy.lock:
                if proxy.first_play_path is None:
                    proxy.first_play_path = endpoint.path
                next_episode = proxy.first_play_path != endpoint.path
                inject = next_episode and not proxy.prefetch_failed
                if inject:
                    proxy.prefetch_failed = True
                elif next_episode:
                    proxy.prefetch_retried = True
            if inject:
                self.send_error(503)
                return
        media = endpoint.path.startswith('/api/media/')
        if media and proxy.in_outage():
            with proxy.lock:
                proxy.dropped_paths.add(endpoint.path)
            proxy.interrupted.set()
            self.send_error(503)
            return
        target = proxy.upstream
        cls = http.client.HTTPSConnection if target.scheme == 'https' else http.client.HTTPConnection
        conn = cls(target.hostname, target.port, timeout=25)
        try:
            headers = {k: self.headers[k] for k in ('Authorization','Range','If-Range','Accept-Encoding') if k in self.headers}
            conn.request(self.command, target.path.rstrip('/') + self.path, headers=headers)
            response = conn.getresponse()
            self.send_response(response.status)
            for k in ('Content-Type','Content-Length','Content-Range','ETag','Accept-Ranges','Cache-Control','X-Hongguo-Origin'):
                if response.getheader(k):
                    self.send_header(k, response.getheader(k))
            self.end_headers()
            if self.command == 'HEAD':
                return
            while chunk := response.read1(32 * 1024):
                if media and proxy.in_outage():
                    with proxy.lock:
                        proxy.dropped_paths.add(endpoint.path)
                    proxy.interrupted.set()
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                self.wfile.write(chunk)
                if media:
                    with proxy.lock:
                        previously_cut = endpoint.path in proxy.dropped_paths
                    if previously_cut and response.status == 206 and not proxy.in_outage():
                        proxy.resumed.set()
                    if not proxy.marker.exists():
                        time.sleep(len(chunk)/900_000)
        except (OSError, http.client.HTTPException):
            self.close_connection = True
        finally:
            conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--case', required=True, choices=['build','direct','relay','direct-fixture'])
    parser.add_argument('--config', type=Path, help='Private baseURL/token/seriesID JSON, required only for relay.')
    parser.add_argument('--prefetch-fault', action='store_true', help='Relay only. Also fail the first lookup for episode two.')
    parser.add_argument('--ffmpeg', default=shutil.which('ffmpeg'), help='Needed only for direct-fixture.')
    parser.add_argument('--direct-series', default='7642275752825605144,20', help='Catalog ID,first episode (direct only)')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if args.case == 'build':
        build(output)
        return
    inventory = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','--json']))['devices']
    device = next((d for group in inventory.values() for d in group if d['udid'] == args.device and d.get('isAvailable')), None)
    if not device:
        parser.error('Only an available iOS Simulator is supported')
    if args.case == 'relay' and not args.config:
        parser.error('Relay needs --config')
    if device['state'] != 'Booted':
        run('xcrun','simctl','boot',args.device)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    proxy = None
    private = None
    try:
        run('xcrun','simctl','bootstatus',args.device,'-b')
        run('xcrun','simctl','install',args.device,str(output/'DerivedData/Build/Products/Debug-iphonesimulator/Hongguo.app'))
        data = Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.device,BUNDLE,'data'],text=True).strip())/'Documents'
        data.mkdir(exist_ok=True)
        marker = data/'outage-until'
        marker.unlink(missing_ok=True)
        if args.case == 'direct':
            (data/'direct-series').write_text(args.direct_series)
        if args.case == 'direct-fixture':
            if not args.ffmpeg:
                parser.error('direct-fixture requires --ffmpeg')
            media = output/'generated-clips'
            media.mkdir(exist_ok=True)
            for code, pattern in [('201','testsrc2'),('202','smptebars')]:
                clip = media/(code+'.mp4')
                if not clip.exists():
                    run(args.ffmpeg,'-v','error','-f','lavfi','-i',pattern+'=size=640x360:rate=24:duration=32',
                        '-an','-c:v','libx264','-preset','ultrafast','-b:v','1800k','-minrate','1800k',
                        '-maxrate','1800k','-bufsize','1800k','-x264-params','nal-hrd=cbr','-movflags','+faststart',str(clip))
            spec = importlib.util.spec_from_file_location('clip_server', ROOT/'Tests/PlaybackInterruptionSimulator/fixture_server.py')
            sys.dont_write_bytecode = True
            fixture_module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(fixture_module)
            proxy = fixture_module.LocalClips(media, marker)
            threading.Thread(target=proxy.serve_forever,daemon=True).start()
            (data/'fixture-port').write_text(str(proxy.server_port))
        if args.case == 'relay':
            cfg = json.loads(args.config.read_text())
            proxy = RelayFaultProxy(cfg['baseURL'], marker)
            proxy.inject_prefetch = args.prefetch_fault
            threading.Thread(target=proxy.serve_forever,daemon=True).start()
            private = data/'relay-config.json'
            private.touch(mode=0o600, exist_ok=True)
            private.write_text(json.dumps({**cfg,'baseURL':'http://127.0.0.1:'+str(proxy.server_port)}))
        stdout, stderr = (output/(args.case+ext) for ext in ('.stdout','.stderr'))
        for log in (stdout,stderr):
            log.unlink(missing_ok=True)
        run('xcrun','simctl','launch','--terminate-running-process','--stdout='+str(stdout),'--stderr='+str(stderr),
            args.device,BUNDLE,'qa-'+args.case,'-playback-health-diagnostics','-playback-buffer-diagnostics')
        deadline = time.monotonic()+365
        while time.monotonic()<deadline:
            logs = stdout.read_text(errors='replace') if stdout.exists() else ''
            if 'CONTINUITY RESULT' in logs or 'CONTINUITY FAIL' in logs:
                if proxy:
                    failed = proxy.interrupted.is_set()
                    recovered = proxy.resumed.is_set()
                else:
                    failed = 'FAULT direct transfer interrupted' in logs
                    recovered = 'FAULT direct transfer restored' in logs
                transport = f'TRANSPORT interrupted={int(failed)} bytesAfterOutage={int(recovered)}'
                if args.prefetch_fault and args.case == 'relay':
                    transport += f' nextLookup503={int(proxy.prefetch_failed)} nextLookupRetried={int(proxy.prefetch_retried)}'
                    recovered = recovered and proxy.prefetch_failed and proxy.prefetch_retried
                (output/(args.case+'-result.txt')).write_text('\n'.join(line for line in logs.splitlines() if line.startswith('CONTINUITY '))+'\n'+transport+'\n')
                print((output/(args.case+'-result.txt')).read_text(),flush=True)
                return 0 if 'CONTINUITY RESULT' in logs and failed and recovered else 1
            time.sleep(0.5)
        raise TimeoutError('No final simulator result')
    finally:
        subprocess.run(['xcrun','simctl','terminate',args.device,BUNDLE],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if private:
            private.unlink(missing_ok=True)
        if proxy:
            proxy.shutdown()
            proxy.server_close()
        subprocess.run(['xcrun','simctl','shutdown',args.device],check=True)


if __name__ == '__main__':
    raise SystemExit(main())
