#!/usr/bin/env python3
"""Capture DEBUG UI fixtures in an already booted iPad simulator; never start a session."""
import argparse
import json
import plistlib
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--device', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--settle-seconds', type=float, default=4)
parser.add_argument('--rotation', type=int, choices=[-90, 0, 90, 180], default=0,
                    help='Rotate saved pixels to match the app orientation on a portrait simulator display.')
parser.add_argument('--pages', nargs='+', default=['waiting', 'connected', 'wifi', 'recovering', 'video-recovery', 'error', 'pairing', 'settings', 'connection', 'help', 'diagnostics', 'about'])
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((args.app / 'Info.plist').read_bytes())
bundle = info['CFBundleIdentifier']
code_images = [args.app / info['CFBundleExecutable'], *args.app.glob('*.debug.dylib')]
if not any(b'-PadInkUIFixture' in path.read_bytes() for path in code_images):
    parser.error('The app must be a DEBUG build containing PadInkUIFixture; release apps start real sessions.')

def sim(*command):
    subprocess.run(['xcrun', 'simctl', *command], check=True, capture_output=True, text=True)

sim('install', args.device, str(args.app))
sim('launch', '--terminate-running-process', args.device, bundle, '-PadInkUIFixture', 'waiting')
time.sleep(max(6, args.settle_seconds))  # First launch may still be compiling Metal shaders.
shots = []
for appearance in ['light', 'dark']:
    sim('ui', args.device, 'appearance', appearance)
    for page in args.pages:
        sim('launch', '--terminate-running-process', args.device, bundle, '-PadInkUIFixture', page)
        time.sleep(args.settle_seconds)
        name = f'ipad-{page}-{appearance}.png'
        sim('io', args.device, 'screenshot', str(args.output / name))
        if args.rotation:
            subprocess.run(['sips', '-r', str(args.rotation), str(args.output / name)], check=True, capture_output=True)
        shots.append({'file': name, 'page': page, 'appearance': appearance, 'fixture': True})
        print(name, flush=True)
sim('terminate', args.device, bundle)
manifest = {'note': 'Actual SwiftUI UI fixtures. No connection or video session is started; mirror is labeled as a preview. Simulator build may require the documented temporary Metal compile shim.', 'device': args.device, 'savedPixelRotation': args.rotation, 'screenshots': shots}
(args.output / 'ipad-screenshots.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
