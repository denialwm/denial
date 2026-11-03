import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import Mock
import json

loader = importlib.machinery.SourceFileLoader(
    'denial_benchmark', str(Path(__file__).resolve().parents[1] / 'tools/denial-benchmark'))
spec = importlib.util.spec_from_loader(loader.name, loader)
bench = importlib.util.module_from_spec(spec)
loader.exec_module(bench)


class AccountingTests(unittest.TestCase):
    def phase(self):
        def snapshot(time, ticks, gpu):
            return {'monotonic_ns': time,
                    'process': {'start': 1, 'ticks': ticks, 'rss_pages': 100},
                    'threads': {'1': {'start': 1, 'ticks': ticks, 'name': 'raster'}},
                    'gpu': {'clients': {'msm//2': {'drm-engine-gpu': gpu}}, 'unavailable': []}}
        return {'name': 'unit', 'actions': [], 'begin_ns': 0, 'end_ns': 1_000_000_000,
                'timings': {'frames': [[1, 1000, 9000, 11000], [8334, 2000, 7000, 10000]],
                            'overflow': False},
                'resources_begin': snapshot(0, 100, 0),
                'resources_end': snapshot(1_000_000_000, 125, 250_000_000)}

    def test_one_core_cpu_gpu_and_budget(self):
        result = bench.summarize_phase(self.phase(), 100, 8_333_333)
        self.assertEqual(result['cpu_one_core_percent'], 25)
        self.assertEqual(result['gpu_engine_busy_percent']['msm//2']['drm-engine-gpu'], 25)
        self.assertEqual(result['raster_over_budget'], 1)
        self.assertEqual(result['work']['cpu_ms'], 250)
        self.assertAlmostEqual(result['work']['cpu_ms_per_refresh_interval'], 2.08333325)
        self.assertEqual(result['work']['gpu']['msm//2']['execution_ms'], 250)

    def test_gpu_cycles_are_separate_from_busy_time(self):
        phase = self.phase()
        phase['resources_begin']['gpu']['clients']['msm//2']['drm-cycles-gpu'] = 100
        phase['resources_end']['gpu']['clients']['msm//2']['drm-cycles-gpu'] = 125000100
        result = bench.summarize_phase(phase, 100, 8_333_333)
        self.assertEqual(result['work']['gpu']['msm//2']['effective_clock_mhz'], 500)
        self.assertNotIn('drm-cycles-gpu', result['gpu_engine_busy_percent']['msm//2'])

    def test_timing_batches_exclude_frames_outside_measured_interval(self):
        phase = self.phase()
        phase.update(begin_ns=1_000_000, end_ns=5_000_000)
        phase['timings']['frames'] = [
            [999, 100_000, 100_000, 200_000],
            [1000, 1000, 9000, 11000],
            [2500, 2000, 7000, 10000],
            [5000, 100_000, 100_000, 200_000],
            [5001, 100_000, 100_000, 200_000],
        ]
        result = bench.summarize_phase(phase, 100, 8_333_333)
        self.assertEqual(result['timing_window'], {
            'captured_samples': 5, 'samples_in_phase': 2, 'samples_outside_phase': 3})
        self.assertEqual(result['build_us']['p95'], 2000)
        self.assertEqual(result['raster_us']['p95'], 9000)
        self.assertEqual(result['raster_over_budget'], 1)
        self.assertEqual(result['vsync_intervals_us']['p50'], 1500)

    def test_hardware_counter_unavailability_and_multiplexing_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'perf.csv'
            path.write_text('1234,,cycles,5678,75.00,,\n<not supported>,,bus-access,0,0,,\n')
            counters = bench.parse_hardware_counters(path)
            self.assertEqual(counters['cycles']['count'], 1234)
            self.assertEqual(counters['cycles']['running_percent'], 75)
            self.assertIn('unavailable', counters['bus-access'])

    def test_native_frame_denominator_rejects_loss_ambiguity_and_repeated_edges(self):
        events = [{'file': 'native', 'crtc': 0, 'sequence': 1},
                  {'file': 'native', 'crtc': 0, 'sequence': 2}]
        self.assertEqual(bench.native_presentation_count(events, {'lost_events': 0}), 2)
        self.assertIsNone(bench.native_presentation_count(events, {'lost_events': 1}))
        self.assertIsNone(bench.native_presentation_count(events + [events[0]], {'lost_events': 0}))
        self.assertIsNone(bench.native_presentation_count(events + [
            {'file': 'other', 'crtc': 0, 'sequence': 3}], {'lost_events': 0}))

    def test_client_latency_uses_comparable_clocks_and_presentation_window(self):
        events = [{'event': 'started', 'clock_id': bench.time.CLOCK_MONOTONIC},
                  {'event': 'presented', 'presentation_ns': 1999, 'submitted_ns': 0},
                  {'event': 'presented', 'presentation_ns': 2000, 'submitted_ns': 1000},
                  {'event': 'presented', 'presentation_ns': 4500, 'submitted_ns': 3000},
                  {'event': 'presented', 'presentation_ns': 3000, 'submitted_ns': 3500},
                  {'event': 'presented', 'presentation_ns': 3500},
                  {'event': 'presented', 'presentation_ns': 5000, 'submitted_ns': 0}]
        result = bench.summarize_workload_presentation(events, 2000, 5000, 8_333_333)
        self.assertEqual(result['frames'], 4)
        self.assertEqual(result['submit_to_presentation_us']['count'], 2)
        self.assertEqual(result['submit_to_presentation_us']['mean'], 1.25)
        self.assertEqual(result['submit_to_presentation_us']['p95'], 1.5)
        self.assertEqual(result['submit_latency_quality'], {
            'usable_samples': 2, 'missing_submit_timestamp': 1, 'negative_intervals': 1})
        events[0]['clock_id'] = -1
        unavailable = bench.summarize_workload_presentation(events, 2000, 5000, 8_333_333)
        self.assertIn('unavailable', unavailable)
        self.assertNotIn('submit_to_presentation_us', unavailable)

    def test_process_restart_rejected(self):
        phase = self.phase()
        phase['resources_end']['process']['start'] = 2
        with self.assertRaises(RuntimeError):
            bench.summarize_phase(phase, 100, 8_333_333)

    def test_fixed_clock_check_uses_hardware_readback_and_sparse_samples(self):
        prefix = '/sys/devices/system/cpu/cpufreq/policy0/'
        rows = [{'metrics': {}}, {'metrics': {
            prefix + 'cpuinfo_cur_freq': '1996800',
            prefix + 'scaling_min_freq': '2112000',
            prefix + 'scaling_max_freq': '2112000'}}]
        result = bench.summarize_clocks(rows, {'policy0': {
            'scaling_min_freq': '2112000', 'scaling_max_freq': '2112000'}})['policy0']
        self.assertEqual(result['cpuinfo_cur_freq']['count'], 1)
        self.assertEqual(result['reported_clock_deviations'], 1)
        self.assertEqual(result['limit_deviations'], 0)

    def test_render_readiness_requires_presented_feedback_after_start(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'client.jsonl'
            events = [{'event': 'started', 'clock_id': bench.time.CLOCK_MONOTONIC,
                       'presentation_available': True},
                      {'event': 'discarded', 'frame': 0},
                      {'event': 'presented', 'frame': 1, 'presentation_ns': 123}]
            path.write_text(''.join(json.dumps(e) + '\n' for e in events))
            process = Mock(returncode=None)
            process.poll.return_value = None
            self.assertEqual(bench.wait_render_ready(path, process)['first_presented']['frame'], 1)
            process.poll.return_value = 1
            with self.assertRaisesRegex(RuntimeError, 'exited before presentation'):
                bench.wait_render_ready(path, process)

    def test_duplicate_drm_fds_count_client_once(self):
        class Entry:
            def __init__(self, value): self.value = value
            def read_text(self): return self.value
        entries = [Entry('drm-driver: msm\ndrm-client-id: 2\ndrm-engine-gpu: 10 ns\n'),
                   Entry('drm-driver: msm\ndrm-client-id: 2\ndrm-engine-gpu: 12 ns\n')]
        with patch.object(Path, 'iterdir', return_value=iter(entries)):
            result = bench.gpu(123)
        self.assertEqual(result['clients'], {'msm//2': {'drm-engine-gpu': 12}})

    def test_gpu_memory_is_a_deduplicated_gauge_with_explicit_units(self):
        class Entry:
            name = '7'
            def __init__(self, value): self.value = value
            def read_text(self): return self.value
        prefix = 'drm-driver: msm\ndrm-client-id: 2\n'
        entries = [Entry(prefix + 'drm-resident-memory: 1024 KiB\n'),
                   Entry(prefix + 'drm-resident-memory: 1024 KiB\ndrm-total-memory: 9 unknown\n')]
        with patch.object(Path, 'iterdir', return_value=iter(entries)):
            state = bench.gpu(123)
        self.assertEqual(state['clients']['msm//2'], {'drm-resident-memory': 1024**2})
        rows = [{'monotonic_ns': n, 'gpu': {'clients': {'msm//2': {
                    'drm-resident-memory': memory * 1024**2}}}}
                for n, memory in [(3, 1), (1, 2), (2, 5)]]
        self.assertEqual(bench.summarize_gpu_memory(rows)['msm//2']['drm-resident-memory'],
                         {'first': 2, 'last': 1, 'peak': 5})

    def test_cached_gpu_sampling_keeps_one_fd_per_client(self):
        class Entry:
            def __init__(self, name, client, engine):
                self.name, self.client, self.engine = name, client, engine
            def read_text(self):
                return f'drm-driver: msm\ndrm-client-id: {self.client}\ndrm-engine-gpu: {self.engine} ns\n'
        entries = [Entry('7', 2, 10), Entry('8', 2, 12), Entry('9', 3, 33)]
        with patch.object(Path, 'iterdir', return_value=iter(entries)):
            result = bench.gpu(123)
        self.assertEqual(result['fd_names'], ['7', '9'])
        self.assertEqual(result['clients']['msm//2']['drm-engine-gpu'], 12)
        self.assertEqual(result['clients']['msm//3']['drm-engine-gpu'], 33)

    def test_system_memory_reports_headroom_without_inventing_missing_values(self):
        rows = [{'meminfo': 'MemAvailable: 2048 kB\nShmem: 4096 kB\nAnonPages: 3072 kB\n'},
                {'meminfo': 'MemAvailable: 1024 kB\nShmem: 5120 kB\n'},
                {'meminfo': None}]
        self.assertEqual(bench.summarize_system_memory(rows), {
            'available_samples': 2, 'min_available_mib': 1,
            'max_shmem_mib': 5, 'max_anon_mib': 3})
        self.assertIsNone(bench.summarize_system_memory([{}])['min_available_mib'])

    def test_proc_names_with_spaces_and_parentheses(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'stat'
            fields = ['0'] * 40
            fields[11], fields[12], fields[19], fields[21], fields[36] = '7', '8', '99', '20', '3'
            path.write_text('123 (Shm (dropping) th) ' + ' '.join(fields))
            self.assertEqual(bench.stat(path)['ticks'], 15)
            self.assertEqual(bench.stat(path)['start'], 99)


class AuditTests(unittest.TestCase):
    def test_audit_preflight_respects_native_precedence_and_engine_parser(self):
        self.assertFalse(bench.diagnostic_audit_active({'DENIAL_RENDER_AUDIT': 'false'}))
        self.assertFalse(bench.diagnostic_audit_active({
            'DENIAL_RENDER_AUDIT': '0', 'DENIA_RENDER_AUDIT': 'true'}))
        self.assertTrue(bench.diagnostic_audit_active({'DENIAL_RENDER_AUDIT': ' YES '}))
        self.assertTrue(bench.diagnostic_audit_active({'DENIA_RENDER_AUDIT': 'on'}))
        self.assertTrue(bench.diagnostic_audit_active({'DENIA_GPU_STAGE_AUDIT': 'false'}))
        self.assertFalse(bench.diagnostic_audit_active({'DENIA_GPU_STAGE_AUDIT': '0'}))

    def test_journal_binary_messages_and_capture_identity(self):
        row = {'_PID': '4', '_BOOT_ID': 'abc123', '__MONOTONIC_TIMESTAMP': '2000',
               'MESSAGE': list(b'\x1b[32mFlutter per-output render audit\x1b[0m interval_ms=1000')}
        messages = bench.journal_audit_messages([
            dict(row, _PID='5'), dict(row, _BOOT_ID='other'), row], 4, 'abc-123')
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]['monotonic_ns'], 2_000_000)
        self.assertNotIn('\x1b', messages[0]['message'])

    def test_phase_boundaries_weighting_missing_samples_and_nested_stage_scope(self):
        phase = {'name': 'unit', 'begin_ns': 2_000_000_000, 'end_ns': 8_000_000_000}
        def gpu(end, count, average):
            return {'monotonic_ns': end, 'message':
                f'Flutter per-output render audit interval_ms=1000 gpu_render_samples={count} '
                f'gpu_flutter_render_avg_us={average} gpu_scanout_blit_avg_us=0 '
                f'gpu_frame_avg_us={average} gpu_frame_p95_us={average + 100} '
                'gpu_timer_disjoint=0 gpu_timer_abandoned=0'}
        messages = [gpu(2_500_000_000, 100, 99999), gpu(4_000_000_000, 2, 1000),
                    gpu(6_000_000_000, 6, 2000), gpu(9_000_000_000, 100, 99999),
                    {'monotonic_ns': 5_000_000_000, 'message':
                     'Denial/Volition output scheduler audit interval_ms=1000 ready_published=10 stale_ready_drops=3'},
                    {'monotonic_ns': 5_000_000_000, 'message':
                     'Denial GPU stage audit interval_ms=1000 disjoint=2 abandoned=1 '
                     'root_pass=2:total_us=90/avg_us=45/p95_us=80/max_us=85/pixels=100 '
                     'root_solid=2:total_us=20/avg_us=10/p95_us=12/max_us=15/pixels=100'}]
        result = bench.summarize_audit_phase(phase, messages)
        self.assertEqual(result['native_render_markers']['samples'], 8)
        self.assertEqual(result['native_render_markers']['gpu_frame_avg_us'], 1750)
        self.assertEqual(result['native_render_markers']['interval_p95_us_range'], [1100, 2100])
        self.assertEqual(result['scheduler']['stale_ready_fraction'], .3)
        diagnostic = result['engine_gpu_diagnostic']
        self.assertEqual(diagnostic['disjoint_samples'], 2)
        self.assertEqual(diagnostic['abandoned_samples'], 1)
        self.assertEqual(diagnostic['stages']['root_pass']['recorded_gpu_us'], 90)
        self.assertEqual(diagnostic['stages']['root_solid']['recorded_gpu_us'], 20)
        self.assertNotIn('total_gpu_us', diagnostic)
        self.assertFalse(diagnostic['timings_usable'])
        self.assertFalse(result['native_render_markers']['timings_usable'])

    def test_clean_native_markers_do_not_validate_lossy_concurrent_stage_queries(self):
        phase = {'name': 'unit', 'begin_ns': 0, 'end_ns': 2_000_000_000}
        native = {'monotonic_ns': 1_000_000_000, 'message':
                  'Flutter per-output render audit interval_ms=1000 gpu_render_samples=5 '
                  'gpu_frame_avg_us=1000 gpu_timer_disjoint=0 gpu_timer_abandoned=0'}
        stage = 'Denial GPU stage audit interval_ms=1000 {} '
        samples = 'root_pass=5:total_us=5000/avg_us=1000/p95_us=1000/max_us=1000/pixels=100'
        clean = bench.summarize_audit_phase(phase, [native])
        self.assertTrue(clean['native_render_markers']['timings_usable'])
        self.assertFalse(clean['engine_gpu_diagnostic']['timings_usable'])
        for counters, usable in [('disjoint=0 abandoned=0', True),
                                 ('disjoint=1 abandoned=0', False),
                                 ('disjoint=0 abandoned=1', False)]:
            with self.subTest(counters=counters):
                result = bench.summarize_audit_phase(phase, [native,
                    {'monotonic_ns': 1_000_000_000, 'message': stage.format(counters) + samples}])
                self.assertEqual(result['engine_gpu_diagnostic']['timings_usable'], usable)
                self.assertEqual(result['native_render_markers']['timings_usable'], usable)
                self.assertEqual(result['engine_gpu_diagnostic']['recorded_samples'], 5)
                # Retained observations remain available even when withheld.
                self.assertEqual(result['native_render_markers']['gpu_frame_avg_us'], 1000)

    def test_unknown_interval_and_missing_gpu_field_are_not_zero_cost(self):
        phase = {'name': 'unit', 'begin_ns': 0, 'end_ns': 2_000_000_000}
        result = bench.summarize_audit_phase(phase, [
            {'monotonic_ns': 1_000_000_000, 'message':
             'Flutter per-output render audit interval_ms=1000 gpu_render_samples=5'},
            {'monotonic_ns': 1_000_000_000, 'message':
             'Flutter per-output render audit gpu_render_samples=100'}])
        self.assertEqual(result['native_render_markers']['samples'], 5)
        self.assertIsNone(result['native_render_markers']['gpu_frame_avg_us'])
        self.assertFalse(result['native_render_markers']['timings_usable'])

    def test_report_rejects_another_capture_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'metadata.json').write_text(json.dumps({'pid': 4, 'boot_id': 'abc123'}))
            journal = root / 'journal.jsonl'
            journal.write_text(json.dumps({'_PID': '5', '_BOOT_ID': 'abc123',
                '__MONOTONIC_TIMESTAMP': '2000', 'MESSAGE': 'Flutter per-output render audit'}) + '\n')
            with self.assertRaisesRegex(RuntimeError, 'PID and boot'):
                bench.audit_report(root, journal)


if __name__ == '__main__':
    unittest.main()
