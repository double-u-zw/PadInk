#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('perf', Path(__file__).with_name('analyze-pencil-performance.py'))
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)

class AnalysisTests(unittest.TestCase):
    def test_percentiles(self):
        self.assertEqual(p.distribution(list(range(1, 101))), dict(n=100, p50=50, p95=95, p99=99, max=100))
        self.assertIsNone(p.distribution([]))
    def test_clock_offset_not_raw_subtraction(self):
        # iPad uptime is 5s ahead. Four timestamps imply 2ms one-way +/-2ms.
        offset, m = 5_000_000_000, 1_000_000
        common = [dict(stage='experiment.begin', time=0, attachment='A'), dict(stage='experiment.end', time=45_000*m, attachment='A')]
        clocks = []
        for a in (2900*m, 3100*m):
            clocks.append(dict(stage='clock.exchange', time=a+4*m, attachment='A', t1=a, t2=a+offset+2*m, t3=a+offset+2*m, t4=a+4*m))
        mac = dict(events=common + clocks + [dict(stage='wire.receive', time=3002*m, attachment='A', stream=1, frame=9, code='257')])
        pad = dict(events=common + [dict(stage='wire.send', time=3000*m+offset, attachment='A', stream=1, frame=9)])
        result = p.cross_device(mac, pad)
        self.assertEqual(result['pairedPencilFrames'], 1)
        self.assertEqual(result['estimatedOneWayLowerMs']['p50'], 0)
        self.assertEqual(result['estimatedOneWayUpperMs']['p50'], 4)
        self.assertEqual(result['uncertaintyWidthMs']['max'], 4)
    def test_partial_window_rejected(self):
        with self.assertRaises(ValueError):
            p.window(dict(events=[dict(stage='experiment.begin', time=0, attachment='A')]))
    def test_wire_type_matches_registry(self):
        self.assertIn('pencil = Self(rawValue: 0x0101)', Path('Sources/PadInkCore/Protocol/MessageRegistry.swift').read_text())

if __name__ == '__main__': unittest.main()
