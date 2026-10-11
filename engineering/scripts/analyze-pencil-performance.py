#!/usr/bin/env python3
"""Read paired Debug performance exports. Print metadata-only statistics; never infer app consumption."""
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path


def distribution(values):
    values = sorted(values)
    if not values:
        return None
    def percentile(p):
        return round(values[max(0, math.ceil(len(values) * p) - 1)], 3)
    return dict(n=len(values), p50=percentile(.5), p95=percentile(.95), p99=percentile(.99), max=round(values[-1], 3))


def ms(n):
    return n / 1_000_000


def load(path):
    report = json.loads(Path(path).read_text())
    perf = report.get('performance')
    if not perf or perf.get('clockBasis') != 'localMonotonicNanoseconds':
        raise ValueError(f'{path}: requires PADINK_PERF Debug export; support report clocks cannot be paired')
    return report, perf


def window(perf):
    events = perf['events']
    begins = [e for e in events if e['stage'] == 'experiment.begin']
    complete = []
    for candidate in begins:
        ends = [e for e in events if e['stage'] == 'experiment.end' and e.get('attachment') == candidate.get('attachment') and e['time'] >= candidate['time']]
        if len(ends) == 1:
            complete.append((candidate, ends[0]))
    if not complete:
        raise ValueError('no complete experiment window; relaunch for a stable trial')
    begin, end = complete[-1]
    if any(e['stage'] == 'route.ended' and begin['time'] <= e['time'] <= end['time'] for e in events):
        raise ValueError('attachment ended during measurement; invalid trial')
    # Ignore the first two seconds for stopCapture/profile/decoder drain to settle, equally for all modes.
    lo, hi = begin['time'] + 2_000_000_000, end['time']
    return begin, [e for e in events if lo <= e['time'] <= hi]


def summarize(report, perf):
    begin, events = window(perf)
    durations, intervals, peaks, codes = defaultdict(list), defaultdict(list), {}, defaultdict(int)
    previous = {}
    for e in events:
        stage = e['stage']
        if stage in ('stream.queue', 'wire.encode', 'wire.parse', 'wire.writeComplete', 'wire.completionQueue',
                     'input.receiveToPipeline', 'input.sendQueue', 'input.mailbox', 'input.backend', 'input.postCall', 'input.uiCallback',
                     'video.payload', 'video.encodeQueue', 'video.sendQueue', 'video.mediaQueue'):
            if e.get('start') is not None and e.get('end') is not None and e['end'] >= e['start']:
                durations[f"{stage}/stream={e.get('stream', '-')}"].append(ms(e['end'] - e['start']))
        if stage == 'input.raw' and e.get('start') is not None and e['time'] >= e['start']:
            durations['input.sampleToRawTrace.assumedUIKitUptime'].append(ms(e['time'] - e['start']))
        if stage in ('input.raw', 'input.postBegin', 'system.sessionTapObserved'):
            key = (stage, e.get('generation'), e.get('item'))
            if key in previous:
                intervals[stage].append(ms(e['time'] - previous[key]))
            previous[key] = e['time']
        if e.get('depth') is not None:
            peaks[stage] = max(peaks.get(stage, 0), e['depth'])
        if 'drop' in stage.lower() or stage in ('input.action', 'input.cancel', 'input.rejected', 'video.experimentDiscard'):
            codes[f"{stage}:{e.get('code', '')}"] += 1
    routes = [e for e in perf['events'] if e['stage'] == 'route.active' and e.get('attachment') == begin.get('attachment')]
    posts = [e for e in events if e['stage'] == 'input.postBegin' and e.get('code') == 'sample']
    taps = [e for e in events if e['stage'] == 'system.sessionTapObserved']
    by_key = defaultdict(list)
    for e in posts:
        by_key[(e.get('item', 0) & 0xffffffff, e.get('sample', 0) & 0xffffffff)].append(e)
    for e in taps:
        candidates = [p for p in by_key[(e.get('item'), e.get('sample'))] if 0 <= e['time'] - p['time'] < 1_000_000_000]
        if len(candidates) == 1:
            durations['input.postBeginToSessionTap.observerSchedulingIncluded'].append(ms(e['time'] - candidates[0]['time']))
    sequences = defaultdict(list)
    for e in posts:
        sequences[(e.get('generation'), e.get('item'))].append(e.get('sample'))
    gaps = sum(b != a + 1 for seq in sequences.values() for a, b in zip(seq, seq[1:]))
    return dict(role=report.get('session', {}).get('role'), build=report.get('session'), mode=perf['mode'],
                attachment=begin.get('attachment'), routes=routes,
                traceLoss=dict(overwritten=perf['overwritten'], contentionDrops=perf['contentionDrops']),
                measuredSeconds=43, durationsMs={k: distribution(v) for k, v in durations.items()},
                sameStrokeIntervalsMs={k: distribution(v) for k, v in intervals.items()},
                gapsOver50ms={k: sum(x > 50 for x in v) for k, v in intervals.items()},
                gapsOver100ms={k: sum(x > 100 for x in v) for k, v in intervals.items()},
                queueDepthPeaks=peaks, dropsAndActions=dict(codes), observedPostSequenceDiscontinuities=gaps,
                postCount=len(posts), sessionTapCount=len(taps),
                appConsumption='unobserved; neither CGEvent timestamp, post return nor session tap confirms target consumption')


def cross_device(mac, pad):
    mb, me = window(mac); pb, pe = window(pad)
    if mb.get('attachment') != pb.get('attachment'):
        raise ValueError('different attachments: cannot compare clocks or input')
    clocks = []
    for e in mac['events']:
        if e['stage'] != 'clock.exchange' or e.get('attachment') != mb.get('attachment'):
            continue
        a, b, c, d = (e[k] for k in ('t1', 't2', 't3', 't4'))
        network = (d - a) - (c - b)
        if d < a or c < b or network < 0:
            continue
        theta = ((b - a) + (c - d)) / 2  # pad minus Mac
        clocks.append((d, theta, network / 2))
    sent = {(e.get('attachment'), e.get('stream'), e.get('frame')): e for e in pe if e['stage'] == 'wire.send'}
    ranges, ages = [], []
    for e in me:
        if e['stage'] != 'wire.receive' or e.get('code') != '257':
            continue  # PENCIL wire type; checked against MessageRegistry in self-test.
        p = sent.get((e.get('attachment'), e.get('stream'), e.get('frame')))
        if not p:
            continue
        nearby = [c for c in clocks if abs(c[0] - e['time']) <= 5_000_000_000]
        if not nearby:
            continue
        before = [c for c in nearby if c[0] <= e['time']]
        after = [c for c in nearby if c[0] >= e['time']]
        if not before or not after:
            continue
        bracket = [max(before), min(after)]
        low = min(t - u for _, t, u in bracket); high = max(t + u for _, t, u in bracket)
        raw = e['time'] - p['time']
        ranges.append((ms(raw + low), ms(raw + high)))
        ages.append(ms(max(abs(c[0] - e['time']) for c in bracket)))
    return dict(method='four-timestamp pad-minus-Mac offset; envelope of bracketing exchanges within 5s; includes asymmetry uncertainty, assumes bounded drift between exchanges; never raw clock subtraction',
                clockExchanges=len(clocks), offsetSpanMs=ms(max((c[1] for c in clocks), default=0) - min((c[1] for c in clocks), default=0)),
                pairedPencilFrames=len(ranges), estimatedOneWayLowerMs=distribution([r[0] for r in ranges]),
                estimatedOneWayUpperMs=distribution([r[1] for r in ranges]), uncertaintyWidthMs=distribution([r[1]-r[0] for r in ranges]),
                calibrationAgeMs=distribution(ages), warning='Intervals crossing zero or covering the suspected difference are inconclusive. Observation clocks are userspace callbacks, not kernel arrival.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports', nargs='+')
    args = parser.parse_args()
    pairs = [load(p) for p in args.reports]
    output = dict(reports=[summarize(*p) for p in pairs])
    roles = {r.get('session', {}).get('role'): p for r, p in pairs}
    if 'mac' in roles and 'ipad' in roles:
        output['crossDevice'] = cross_device(roles['mac'], roles['ipad'])
    print(json.dumps(output, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
