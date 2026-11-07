#!/usr/bin/env python3
"""Read-only observer for Backend/fixtures synthetic playback in an iOS Simulator.

Never reads account libraries or prints app preferences, content URLs, or identities.
Run after starting the fixture through the app UI. It does not control the app.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import statistics
import subprocess
import time
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container-file', type=Path, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--duration', type=int, default=1200)
    parser.add_argument('--last-episode', type=int, default=300)
    parser.add_argument('--fixture-url', default='http://127.0.0.1:8788')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.duration <= 3600 or args.pid <= 0:
        parser.error('Use a positive process ID and a duration of at most one hour.')
    fixture_url = urlsplit(args.fixture_url)
    if (fixture_url.scheme != 'http' or fixture_url.hostname not in ('127.0.0.1', 'localhost', '::1')
            or fixture_url.username or fixture_url.password or fixture_url.query or fixture_url.fragment
            or fixture_url.path not in ('', '/')):
        parser.error('The fixture URL must be a plain loopback HTTP origin.')
    command = subprocess.check_output(['ps', '-p', str(args.pid), '-o', 'comm='], text=True).strip()
    if not command.endswith('/Hongguo.app/Hongguo'):
        raise SystemExit('The process is not the Hongguo simulator app.')
    container = Path(args.container_file.read_text().strip())
    preferences = container / 'Library/Preferences/tw.mountainp.hongguo.plist'
    libraries = container / 'Library/Application Support/UserLibraries'
    source_id = 'library.v1.bridge.' + hashlib.sha256(args.fixture_url.encode()).hexdigest()
    scope = {'owner': {'guest': {}}, 'sourceID': source_id}
    scope_json = json.dumps(scope, sort_keys=True, separators=(',', ':')).encode()
    library_file = libraries / (hashlib.sha256(scope_json).hexdigest() + '.json')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    samples, records = [], {}
    started = time.monotonic()
    last_report = -60
    error_count = 0
    with args.output.open('w') as output:
        while True:
            try:
                defaults = plistlib.loads(preferences.read_bytes())
                for record in json.loads(defaults.get('playbackDiagnostics.v1', b'[]')):
                    records[record['id']] = record
                synthetic = {}
                state = json.loads(library_file.read_text())
                if state.get('scope') != scope:
                    raise ValueError('Fixture library scope differs.')
                for record in state.get('snapshot', {}).get('episodeHistory', []):
                    if record.get('series', {}).get('id') == '900000000000000001':
                        synthetic[record['episode']['number']] = record
                completed = [number for number, record in synthetic.items()
                             if record.get('duration', 0) > 0 and record.get('seconds', 0) / record['duration'] >= .98]
                rss = int(subprocess.check_output(['ps', '-p', str(args.pid), '-o', 'rss='], text=True).strip()) / 1024
                sample = {'utc': datetime.now(timezone.utc).isoformat(),
                          'elapsed': round(time.monotonic() - started, 2), 'simulator_rss_mb': round(rss, 2),
                          'latest_completed_episode': max(completed, default=0),
                          'completed_synthetic_episodes': len(completed), 'observed_measurements': len(records)}
                samples.append(sample)
                output.write(json.dumps(sample) + '\n'); output.flush()
                if sample['elapsed'] - last_report >= 60:
                    print(json.dumps(sample), flush=True); last_report = sample['elapsed']
                if sample['elapsed'] >= args.duration or args.last_episode in completed:
                    break
            except (OSError, ValueError, KeyError, subprocess.SubprocessError):
                error_count += 1
                if time.monotonic() - started >= args.duration:
                    break
            time.sleep(10)
    first_frames = [r['firstFrameSeconds'] for r in records.values()
                    if r.get('context') != 'replay' and r.get('firstFrameSeconds') is not None]
    summary = {'synthetic_fixture_only': True, 'simulator_not_physical_device': True,
               'observed_seconds': round(time.monotonic() - started, 2),
               'samples': len(samples), 'read_errors': error_count,
               'last_sample': samples[-1] if samples else None,
               'measurement_outcomes': {kind: sum(r.get('outcome') == kind for r in records.values())
                                        for kind in ('completed', 'cancelled', 'failed')},
               'median_first_frame_seconds': statistics.median(first_frames) if first_frames else None,
               'rebuffer_seconds': sum(r.get('rebufferSeconds', 0) for r in records.values()),
               'retries': sum(r.get('recoveryCount', 0) for r in records.values()),
               'minimum_rss_mb': min((s['simulator_rss_mb'] for s in samples), default=None),
               'maximum_rss_mb': max((s['simulator_rss_mb'] for s in samples), default=None)}
    args.output.with_suffix('.summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
