#!/usr/bin/env python3
"""Record exactly which checkout was checked; never claim device or released-binary acceptance."""
import argparse
import importlib.util
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def module():
    spec = importlib.util.spec_from_file_location('release_provenance', ROOT / 'engineering/scripts/rc-release.py')
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def snapshot(scope):
    release = module()
    source, _ = release.source_snapshot(ROOT)
    version, build = release.read_version(ROOT)
    event_sha = os.environ.get('GITHUB_SHA') if scope == 'ci' else None
    if scope == 'ci' and (source['dirty'] or (event_sha and event_sha != source['head'])):
        raise ValueError('CI must check the clean event checkout (PR merge SHA for pull_request)')
    def output(*args):
        return subprocess.check_output(args, text=True).strip()
    return {'version': version, 'build': build, 'source': source, 'scope': scope,
            'githubEventSHA': event_sha, 'githubEvent': os.environ.get('GITHUB_EVENT_NAME') if scope == 'ci' else None,
            'toolchain': {'xcode': output('xcodebuild', '-version'), 'swift': output('swift', '--version'),
                          'macSDK': output('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
                          'ipadSDK': output('xcrun', '--sdk', 'iphoneos', '--show-sdk-version')},
            'dependencies': {'swiftPMExternalPackages': [], 'packageManifestSHA256': release.file_sha(ROOT / 'Package.swift')},
            'buildConfiguration': {'configuration': os.environ.get('PADINK_BUILD_CONFIGURATION', 'Release'),
                                   'variant': os.environ.get('PADINK_BUILD_VARIANT', 'release'),
                                   'channel': os.environ.get('PADINK_BUILD_CHANNEL', 'preview'), 'distribution': 'unsigned',
                                   'codeSigningAllowed': False,
                                   'macArchitectures': os.environ.get('PADINK_MAC_ARCHITECTURES', 'arm64').split(),
                                   'ciBundlePrefixOverride': 'dev.padink.ci' if scope == 'ci' else None},
            'result': 'running', 'claim': 'this checkout only; no installed/released binary or TestFlight USB acceptance'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'finish'])
    parser.add_argument('file', type=Path)
    parser.add_argument('--scope', choices=['local', 'ci'], default='local')
    args = parser.parse_args()
    current = snapshot(args.scope)
    # Package.swift currently has no external packages. Fail if this fact changes instead of
    # silently recording an empty dependency list for a new dependency graph.
    package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'], cwd=ROOT, text=True))
    if package['dependencies']:
        raise ValueError('external dependencies added; freeze their resolved revisions before release checks')
    if args.action == 'finish':
        before = json.loads(args.file.read_text())
        if current != before:
            raise ValueError('checkout/toolchain changed during checks; results do not describe one frozen input')
        current['result'] = 'passed'
    args.file.parent.mkdir(parents=True, exist_ok=True)
    args.file.write_text(json.dumps(current, indent=2) + '\n')
    print(f"{current['result']}: {current['source']['label']} tree={current['source']['treeSHA256']} scope={args.scope}; checkout only")


if __name__ == '__main__':
    main()
