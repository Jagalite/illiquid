#!/usr/bin/env python3
"""Independent receipt/provenance audit; never imports benchmark runner code."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import itertools
import json
import math
from pathlib import Path
import re
import statistics
import subprocess

ROOT = Path('/workspace/scratch/aa79f7e1d859/illiquid')
EVIDENCE = Path('/tmp/illiquid-auxiliary-linux-final-aa79')
EXPECTED_BASE = '4abf4b44f13386ccd04f1ce4ad0e756255ca4d14'
CASES = ['none', 'fonts-128kib', 'fonts-2mib', 'fonts-16mib', 'fonts-64mib', 'mixed']
COUNTS = [0, 1, 2]
VARIANTS = ['baseline', 'candidate']
METRICS = ['allocator_open_delta_bytes', 'allocator_while_open_bytes',
           'allocator_release_delta_bytes', 'process_max_rss_while_open_bytes',
           'opening_wall_seconds', 'opening_cpu_seconds', 'total_retained_payload_bytes']
DEMUXER = 'Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift'
STREAMS = 'Sources/IlliquidNativePlayback/Media/FFmpegStreamInfo.swift'
TIME = 'Sources/IlliquidNativePlayback/Media/MediaTime.swift'
FONT = 'Sources/IlliquidNativePlayback/Subtitles/FontAttachmentStore.swift'
PRESENTER = 'Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift'
SHIM = 'Sources/CFFmpeg/include/ffmpeg_shim.h'


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def read_json(path: Path):
    return json.loads(path.read_text())


def rows(path: Path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--static-only', action='store_true')
    args = parser.parse_args()
    report = {
        'auditor': '/root/attachment_review',
        'independent_script': str(Path(__file__).resolve()),
        'method': 'Direct original/staged/fixture/binary hashes and byte comparisons, raw stdout receipts, independently reconstructed identities/pairs/medians; benchmark Python not imported.',
        'evidence_directory': str(EVIDENCE),
        'audited_at_utc': datetime.now(timezone.utc).isoformat(),
        'mode': 'provenance_only' if args.static_only else 'full_completed_cohort',
        'checks': {}, 'failures': [],
        'limitations': [
            'Linux component evidence: actual FFmpeg open/probe and extracted production media-info projection, not the complete macOS demuxer/executor/player lifecycle.',
            'Native macOS compilation, packet/seek regression execution and real-font rendering execution remain pending; this audit does not qualify them.',
            'Benchmark payloads have supported-font labels but synthetic bytes; the separate actual Noto font fixture is reserved for native rendering regression.',
            'mallinfo2 live bytes are allocator ownership counters, not whole-player resident memory; FFmpeg-owned attachment extradata remains present.',
            'ru_maxrss is a high-water mark and includes a substantial pre-open floor; small-fixture RSS equality cannot establish absence of resident-memory savings.',
            'Six balanced pairs per group support component observations, not universal timing or macOS end-to-end performance claims.',
            'Packet validation exposes complete trace hashes and per-stream counts, not each packet record; this audit verifies every raw receipt and the real-C hashing implementation, without independently re-demuxing fixtures.',
        ],
    }
    checks = defaultdict(lambda: {'passed': 0, 'failed': 0})

    def check(condition, category, description, details=None):
        checks[category]['passed' if condition else 'failed'] += 1
        if not condition:
            failure = {'category': category, 'description': description}
            if details is not None:
                failure['details'] = details
            report['failures'].append(failure)

    manifest = read_json(EVIDENCE / 'manifest.json')
    commands = rows(EVIDENCE / 'commands.jsonl')
    by_label = {command['label']: command for command in commands}
    check(manifest['baseline'] == EXPECTED_BASE, 'cohort_design', 'Immutable baseline matches frozen base')
    check(manifest['cases'] == CASES and manifest['auxiliary_counts'] == COUNTS and manifest['pairs'] == 6,
          'cohort_design', 'Six cases, three auxiliary counts and six pairs')
    check(len(by_label) == len(commands), 'command_receipts', 'Command labels unique')
    for command in commands:
        label = command['label']
        check(command['returncode'] == 0, 'command_receipts', f'{label}: successful exit')
        for stream in ['stdout', 'stderr']:
            path = EVIDENCE / 'logs' / (label + '.' + stream)
            check(file_sha(path) == command[stream + '_sha256'], 'command_receipts', f'{label}: {stream} digest')

    build_labels = [f'build-{v}-{part}' for v in VARIANTS for part in ['projection', 'driver']]
    check([c['label'] for c in commands if c['label'].startswith('build-')] == build_labels,
          'build_provenance', 'Exactly two projection and two driver builds')
    first_build = by_label[build_labels[0]]['argv']
    prefix = Path(first_build[first_build.index('-L') + 1]).parent
    report['ffmpeg_prefix'] = str(prefix)
    for label in build_labels:
        argv = by_label[label]['argv']
        check('-O' in argv and '-warnings-as-errors' in argv and argv[argv.index('-swift-version') + 1] == '6',
              'build_provenance', f'{label}: optimized Swift 6 warnings-as-errors')
        check(all(x in argv for x in ['-lavformat', '-lavcodec', '-lavutil', '-lm']),
              'build_provenance', f'{label}: real FFmpeg libraries')
        check(('OMIT_AUXILIARY_ATTACHMENTS' in argv) == (label == 'build-candidate-driver'),
              'build_provenance', f'{label}: candidate-only harness policy define')
        if label.endswith('driver'):
            check(str(ROOT / 'Benchmarks/AuxiliaryAttachmentPolicy/HarnessLinux.swift') in argv,
                  'build_provenance', f'{label}: actual frozen driver source compiled')

    for name, expected in manifest['driver_sha256'].items():
        snapshot = EVIDENCE / name
        current = ROOT / 'Benchmarks/AuxiliaryAttachmentPolicy' / name
        check(file_sha(snapshot) == expected and file_sha(current) == expected,
              'driver_hashes', f'{name}: frozen copy and current repository match')

    for variant in VARIANTS:
        directory = EVIDENCE / variant
        entry = manifest['sources'][variant]
        original = {}
        for name, expected in entry['original'].items():
            data = (directory / 'original' / name).read_bytes()
            original[name] = data.decode()
            reference = (subprocess.check_output(['git', 'show', EXPECTED_BASE + ':' + name], cwd=ROOT)
                         if variant == 'baseline' else (ROOT / name).read_bytes())
            check(sha(data) == expected and data == reference, 'production_source_hashes', f'{variant}: {name}')
        if variant == 'candidate':
            for name in original:
                if name != DEMUXER:
                    check(entry['original'][name] == manifest['sources']['baseline']['original'][name],
                          'production_source_hashes', f'Supporting source unchanged: {name}')
        for name, expected in entry['staged'].items():
            check(file_sha(directory / name) == expected, 'staged_source_hashes', f'{variant}: {name}')

        # Validate the staged projection by reversing its wrapper/access adaptation.
        projection = (directory / 'Projection.swift').read_text()
        prefix_text, suffix_text = projection.split('enum FFmpegProjection {\n', 1)
        check(suffix_text.endswith('\n}\n'), 'exact_source_adaptation', f'{variant}: projection wrapper')
        restored_suffix = suffix_text[:-3].replace('    static func makeMediaInfo(',
                                                  '    private static func makeMediaInfo(', 1)
        source_suffix = original[DEMUXER][original[DEMUXER].index('    private static func makeMediaInfo('):].rstrip()
        check(restored_suffix + '}' == source_suffix,
              'exact_source_adaptation', f'{variant}: complete original projection and all suffix helpers')
        if variant == 'baseline':
            check(prefix_text == 'import CFFmpeg\nimport Foundation\n' and 'attachmentPolicy' not in restored_suffix,
                  'exact_source_adaptation', 'Baseline contains no policy or extra declarations')
        else:
            policy = re.search(r'^enum FFmpegAttachmentPolicy:.*?^}', original[DEMUXER], re.M | re.S).group()
            check(prefix_text == 'import CFFmpeg\nimport Foundation\n' + policy + '\n',
                  'exact_source_adaptation', 'Candidate uses exact production policy declaration')
        check((directory / 'FFmpegStreamInfo.swift').read_text() == original[STREAMS].replace('import CoreGraphics\n', '', 1),
              'exact_source_adaptation', f'{variant}: complete stream/info types, one import removed')
        check((directory / 'FontAttachmentStore.swift').read_text() == original[FONT],
              'exact_source_adaptation', f'{variant}: complete font admission/validation source')
        time_stage = (directory / 'MediaTime.swift').read_text()
        rational = original[TIME].split('struct FFmpegRational:', 1)[1].split('\nenum MediaTime {', 1)[0].rstrip()
        rational = 'struct FFmpegRational:' + rational
        seconds = original[TIME].split('    static func seconds(', 1)[1].rstrip()
        seconds = '    static func seconds(' + seconds[:-1].rstrip()
        check(time_stage == 'import CFFmpeg\nimport Foundation\n' + rational + '\nenum MediaTime {\n' + seconds + '\n}\n',
              'exact_source_adaptation', f'{variant}: exact rational and seconds implementation')
        error_stage = (directory / 'PresentationError.swift').read_text()
        error_decl = error_stage.removeprefix('import Foundation\n').rstrip()
        check(error_decl.startswith('struct PresentationError:') and error_decl in original[PRESENTER]
              and error_stage == 'import Foundation\n' + error_decl + '\n',
              'exact_source_adaptation', f'{variant}: exact production PresentationError declaration')
        for filename, key in [('harness', 'binary_sha256'), ('libAttachmentProjection.so', 'projection_library_sha256')]:
            check(file_sha(directory / filename) == entry[key], 'binary_hashes', f'{variant}: {filename}')
        receipt = read_json(directory / 'sources.json')
        check(all(receipt[k] == entry[k] for k in receipt), 'production_source_hashes', f'{variant}: sources receipt agrees with manifest')
        link_text = (EVIDENCE / 'logs' / f'linked-libraries-{variant}.stdout').read_text()
        for name in manifest['native_library_sha256']:
            versioned = prefix / name
            soname = '.'.join(versioned.name.split('.')[:3])
            check(f'{soname} => {prefix / "lib" / soname}' in link_text,
                  'build_provenance', f'{variant}: linked {soname} from measured prefix')
        check(f'libAttachmentProjection.so => {directory / "libAttachmentProjection.so"}' in link_text,
              'build_provenance', f'{variant}: linked corresponding projection library')

    shim_path = EVIDENCE / 'CFFmpeg/projection_shim.h'
    shim = shim_path.read_text()
    check(file_sha(shim_path) == manifest['shim_sha256'], 'c_shim', 'Shim hash')
    original_shim = (ROOT / SHIM).read_text()
    original_helpers = re.findall(r'^static inline[^\n]*.*?^}', original_shim, re.M | re.S)
    for name in manifest['production_c_helpers']:
        definitions = [decl for decl in original_helpers if re.search(r'\b' + re.escape(name) + r'\s*\(', decl)]
        check(len(definitions) == 1 and definitions[0] in shim, 'c_shim', f'Exact original C function: {name}')
    check('value.uordblks, value.hblkhd, value.uordblks + value.hblkhd' in shim,
          'c_shim', 'Counts both glibc arena and malloc-owned mmap bytes')
    check(all(call in shim for call in ['av_sha_alloc()', 'av_sha_init(state, 256)', 'av_sha_update(state, data, count)', 'av_sha_final(state, digest)', 'av_free(state)']),
          'c_shim', 'SHA uses real FFmpeg C implementation')
    check((EVIDENCE / 'CFFmpeg/module.modulemap').read_text() == 'module CFFmpeg [system] { header "projection_shim.h" export * }\n',
          'c_shim', 'Module map points at actual generated shim')
    for field in ['native_library_sha256', 'native_header_sha256']:
        for name, expected in manifest[field].items():
            check(file_sha(prefix / name) == expected, field, name)

    fixture_manifest = read_json(EVIDENCE / 'fixture-manifest.json')
    fixtures = {item['name']: item for item in fixture_manifest}
    first_observation_command = by_label['none-aux0-pair0-baseline']
    fixture_dir = Path(first_observation_command['argv'][1]).parent
    report['fixture_directory'] = str(fixture_dir)
    check(read_json(fixture_dir / 'manifest.json') == fixture_manifest, 'fixtures', 'Frozen fixture manifest equals generator output')
    check(set(fixtures) == set(CASES), 'fixtures', 'Exactly six benchmark fixture inventories')
    for case in CASES:
        fixture = fixtures[case]
        path = fixture_dir / fixture['filename']
        check(file_sha(path) == fixture['sha256'] and path.stat().st_size == fixture['size_bytes'],
              'fixtures', f'{case}: complete Matroska size and hash')
        accepted = [a for a in fixture['attachments'] if a['supported_font']]
        rejected = [a for a in fixture['attachments'] if not a['supported_font']]
        check(sum(a['size_bytes'] for a in accepted) == fixture['accepted_payload_bytes']
              and sum(a['size_bytes'] for a in rejected) == fixture['rejected_payload_bytes']
              and len(accepted) == fixture['accepted_attachment_count'],
              'fixtures', f'{case}: independent attachment inventory totals')
        for attachment in fixture['attachments']:
            path = fixture_dir / 'payloads' / attachment['filename']
            check(file_sha(path) == attachment['sha256'] and path.stat().st_size == attachment['size_bytes'],
                  'fixtures', f'{case}: source payload {attachment["filename"]}')

    report['provenance_counts'] = {
        'production_original_files': sum(len(s['original']) for s in manifest['sources'].values()),
        'staged_sources': sum(len(s['staged']) for s in manifest['sources'].values()),
        'drivers': len(manifest['driver_sha256']),
        'native_headers': len(manifest['native_header_sha256']),
        'native_libraries': len(manifest['native_library_sha256']),
        'compiled_projection_libraries': 2, 'compiled_harness_binaries': 2,
        'complete_matroska_fixtures': len(fixtures),
    }

    if not args.static_only:
        completion = read_json(EVIDENCE / 'completion.json')
        observations = rows(EVIDENCE / 'observations.jsonl')
        expected_keys = set(itertools.product(CASES, COUNTS, range(6), VARIANTS))
        observed_keys = [(r['case'], r['auxiliary_count'], r['pair'], r['variant']) for r in observations]
        check(len(observations) == 216 and len(set(observed_keys)) == 216 and set(observed_keys) == expected_keys,
              'complete_cohort', '216 unique expected identities; none missing, extra or duplicated')
        check(completion == {'observations': 216, 'pairs': 108, 'full_validation_groups': 18,
                              'all_font_hashes_match': True, 'all_validation_equal': True, 'commands': len(commands)},
              'complete_cohort', 'Completion receipt totals and flags match independent counts')
        expected_order = []
        for case, count, pair in itertools.product(CASES, COUNTS, range(6)):
            for variant in (VARIANTS if pair % 2 == 0 else list(reversed(VARIANTS))):
                expected_order.append((case, count, pair, variant))
        check(observed_keys == expected_order, 'balanced_pairs', 'Full observation order is frozen AB/BA sequence')
        expected_labels = [f'{case}-aux{count}-pair{pair}-{variant}' for case, count, pair, variant in expected_order]
        measurement_commands = [c for c in commands if c['argv'][0] in [str(EVIDENCE / v / 'harness') for v in VARIANTS]]
        check([c['label'] for c in measurement_commands] == expected_labels,
              'complete_cohort', 'Every observation has exactly one fresh harness subprocess receipt in order')
        lookup = {key: row for key, row in zip(observed_keys, observations)}
        oracles = {}
        cross_count = {}
        raw_receipt_count = 0
        for row in observations:
            case, count, pair, variant = row['case'], row['auxiliary_count'], row['pair'], row['variant']
            label = f'{case}-aux{count}-pair{pair}-{variant}'
            fixture = fixtures[case]
            command = by_label[label]
            check(command['argv'] == [str(EVIDENCE / variant / 'harness'), str(fixture_dir / fixture['filename']), str(count), str(fixture['accepted_payload_bytes'])],
                  'raw_observation_receipts', f'{label}: exact executable and fixture arguments')
            raw = read_json(EVIDENCE / 'logs' / (label + '.stdout'))
            validation = raw.pop('validation')
            row_measurements = {k: v for k, v in row.items() if k not in ['case', 'pair', 'order_position', 'validation_sha256']}
            check(raw == row_measurements, 'raw_observation_receipts', f'{label}: no measurement edited or omitted')
            check(sha(json.dumps(validation, sort_keys=True).encode()) == row['validation_sha256'],
                  'raw_observation_receipts', f'{label}: full validation digest')
            raw_receipt_count += 1
            check(row['order_position'] == (VARIANTS if pair % 2 == 0 else list(reversed(VARIANTS))).index(variant),
                  'balanced_pairs', f'{label}: order position')
            check(row['scope'] == 'actual_ffmpeg_open_probe_plus_extracted_production_projection',
                  'scope', f'{label}: correct component scope')
            font_bytes = fixture['accepted_payload_bytes']
            auxiliary_bytes = count * font_bytes if variant == 'baseline' else 0
            check(row['expected_font_bytes'] == row['primary_retained_payload_bytes'] == font_bytes
                  and row['auxiliary_retained_payload_bytes'] == auxiliary_bytes
                  and row['total_retained_payload_bytes'] == font_bytes + auxiliary_bytes,
                  'payload_ownership', f'{label}: primary retained, exact auxiliary elimination')
            check(row['allocator_while_open_bytes'] == row['allocator_while_open_arena_bytes'] + row['allocator_while_open_mmap_bytes']
                  and row['allocator_open_delta_bytes'] == row['allocator_while_open_bytes'] - row['allocator_before_bytes']
                  and row['allocator_release_delta_bytes'] == row['allocator_after_release_bytes'] - row['allocator_before_bytes'],
                  'numeric_measurements', f'{label}: allocator sums and deltas')
            check(all(isinstance(value, (int, float)) and math.isfinite(value) for key, value in row.items()
                      if key.endswith('_bytes') or key.endswith('_seconds')),
                  'numeric_measurements', f'{label}: all metrics finite')
            check(all(value >= 0 for key, value in row.items()
                      if (key.endswith('_bytes') and 'delta' not in key) or key.endswith('_seconds')),
                  'numeric_measurements', f'{label}: counters/timings nonnegative')
            check(row['process_max_rss_before_bytes'] <= row['process_max_rss_while_open_bytes'] <= row['process_max_rss_after_release_bytes'],
                  'numeric_measurements', f'{label}: high-water RSS monotonic')

            group = (case, count)
            if group not in oracles:
                oracle = read_json(EVIDENCE / 'validation' / f'{case}-aux{count}.json')
                oracles[group] = oracle
                expected_fonts = [{'filename': a['filename'], 'mime_type': a['mime_type'],
                                   'bytes': a['size_bytes'], 'sha256': a['sha256'], 'supported_font': True}
                                  for a in fixture['attachments'] if a['supported_font']]
                check(oracle['primary_attachments'] == expected_fonts,
                      'validation_groups', f'{case}/aux{count}: every primary font byte hash and metadata equals independent fixture inventory')
                # Swift JSONSerialization sorted-key output is compact JSON for these ASCII fields.
                attachment_encoding = json.dumps(expected_fonts, sort_keys=True, separators=(',', ':')).replace('/', '\\/').encode()
                check(oracle['primary_attachments_sha256'] == sha(attachment_encoding),
                      'validation_groups', f'{case}/aux{count}: primary font snapshot digest independently reconstructed')
                metadata, codecs, packets = oracle['metadata'], oracle['codec_parameters'], oracle['packets']
                streams = metadata['streams']
                check([s['index'] for s in streams] == list(range(3 + len(fixture['attachments'])))
                      and [s['kind'] for s in streams] == ['video', 'audio', 'subtitle'] + ['attachment'] * len(fixture['attachments'])
                      and [c['index'] for c in codecs] == list(range(len(streams))),
                      'validation_groups', f'{case}/aux{count}: all media/attachment stream records retained')
                check([metadata[f'selected_{k}_index'] for k in ['video', 'audio', 'subtitle']] == [0, 1, 2]
                      and len(metadata['chapters']) == 1 and metadata['url'] == (fixture_dir / fixture['filename']).as_uri(),
                      'validation_groups', f'{case}/aux{count}: real media selection, chapter and URL')
                expected_extras = [(a['size_bytes'], a['sha256']) for a in fixture['attachments']]
                actual_extras = [(c['extradata_bytes'], c['extradata_sha256']) for c in codecs[3:]]
                check(actual_extras == expected_extras, 'validation_groups',
                      f'{case}/aux{count}: all original FFmpeg attachment extradata, including rejected payloads, retained exactly')
                check(all(c['extradata_bytes'] > 0 and re.fullmatch('[0-9a-f]{64}', c['extradata_sha256']) for c in codecs[:3]),
                      'validation_groups', f'{case}/aux{count}: actual video/audio/subtitle codec-private data hashed')
                check(packets['count'] == sum(packets['stream_counts'].values()) == 24
                      and packets['stream_counts'] == {'0': 12, '1': 11, '2': 1}
                      and re.fullmatch('[0-9a-f]{64}', packets['trace_sha256']) is not None,
                      'validation_groups', f'{case}/aux{count}: complete nonempty expected media packet counts and trace hash')
                normalized = {k: v for k, v in oracle.items() if k != 'input_count'}
                if case in cross_count:
                    check(normalized == cross_count[case], 'validation_groups', f'{case}/aux{count}: equal outputs across auxiliary counts')
                else:
                    cross_count[case] = normalized
            check(validation == oracles[group] and validation['input_count'] == count + 1
                  and validation['auxiliary_policy_verified'] is True
                  and validation['auxiliary_metadata_codec_packet_parity'] is True,
                  'validation_receipts', f'{label}: metadata/codec/extradata/packet/primary-font parity')

        independently_derived_pairs = []
        independently_derived_summary = []
        for case, count in itertools.product(CASES, COUNTS):
            check(Counter(lookup[(case, count, pair, 'baseline')]['order_position'] for pair in range(6)) == {0: 3, 1: 3},
                  'balanced_pairs', f'{case}/aux{count}: three AB and three BA pairs')
            metric_values = defaultdict(list)
            for pair in range(6):
                base = lookup[(case, count, pair, 'baseline')]
                candidate = lookup[(case, count, pair, 'candidate')]
                measurements = {}
                for metric in METRICS:
                    b, c = base[metric], candidate[metric]
                    difference = b - c
                    measurements[metric] = {'baseline': b, 'candidate': c, 'reduction': difference,
                                            'reduction_percent': difference * 100 / b if b else None}
                    metric_values[metric].append(measurements[metric])
                independently_derived_pairs.append({'case': case, 'auxiliary_count': count, 'pair': pair, 'metrics': measurements})
            summarized = {}
            for metric, values in metric_values.items():
                percents = [v['reduction_percent'] for v in values if v['reduction_percent'] is not None]
                summarized[metric] = {
                    'baseline_median': statistics.median(v['baseline'] for v in values),
                    'candidate_median': statistics.median(v['candidate'] for v in values),
                    'paired_reduction_median': statistics.median(v['reduction'] for v in values),
                    'paired_reduction_percent_median': statistics.median(percents) if percents else None,
                    'improved_pairs': sum(v['reduction'] > 0 for v in values),
                    'worse_pairs': sum(v['reduction'] < 0 for v in values),
                }
            independently_derived_summary.append({'case': case, 'auxiliary_count': count, 'pairs': 6, 'metrics': summarized})
        reported_pairs = read_json(EVIDENCE / 'pairs.json')
        reported_summary = read_json(EVIDENCE / 'summary.json')
        check(reported_pairs == independently_derived_pairs, 'summary_arithmetic', 'All 108 paired records, 756 metric differences/percentages recomputed exactly')
        check(reported_summary == independently_derived_summary, 'summary_arithmetic', 'All 18 group summaries, 126 metric aggregates recomputed exactly')
        check(len(list((EVIDENCE / 'validation').glob('*.json'))) == len(oracles) == 18,
              'validation_groups', 'Exactly 18 validation groups')
        report['counts'] = {'observations': len(observations), 'unique_observation_identities': len(set(observed_keys)),
                            'pairs': len(independently_derived_pairs), 'groups': len(independently_derived_summary),
                            'raw_stdout_receipts': raw_receipt_count, 'commands': len(commands),
                            'AB_pairs': 54, 'BA_pairs': 54, 'pairs_per_group': 6}
        effect_groups = {
            'font_bearing_auxiliary_pairs': [p for p in independently_derived_pairs if p['case'] != 'none' and p['auxiliary_count'] > 0],
            'zero_auxiliary_or_no_font_control_pairs': [p for p in independently_derived_pairs if p['case'] == 'none' or p['auxiliary_count'] == 0],
        }
        report['live_allocator_effect_counts'] = {}
        for name, group in effect_groups.items():
            differences = [p['metrics']['allocator_while_open_bytes']['reduction'] for p in group]
            report['live_allocator_effect_counts'][name] = {
                'pairs': len(group), 'improved': sum(d > 0 for d in differences),
                'tied': sum(d == 0 for d in differences), 'worse': sum(d < 0 for d in differences),
            }
        check(report['live_allocator_effect_counts']['font_bearing_auxiliary_pairs'] ==
              {'pairs': 60, 'improved': 60, 'tied': 0, 'worse': 0},
              'observed_memory_effect', 'All 60 font-bearing auxiliary pairs reduce live allocator bytes')
        check(report['live_allocator_effect_counts']['zero_auxiliary_or_no_font_control_pairs'] ==
              {'pairs': 48, 'improved': 0, 'tied': 48, 'worse': 0},
              'observed_memory_effect', 'All 48 no-font/zero-auxiliary controls tie exactly in live allocator bytes')
        report['key_results'] = [{
            'case': g['case'], 'auxiliary_count': g['auxiliary_count'],
            'retained_payload_reduction_bytes': g['metrics']['total_retained_payload_bytes']['paired_reduction_median'],
            'live_allocator_reduction_bytes': g['metrics']['allocator_while_open_bytes']['paired_reduction_median'],
            'live_allocator_reduction_percent': g['metrics']['allocator_while_open_bytes']['paired_reduction_percent_median'],
            'live_allocator_improved_pairs': g['metrics']['allocator_while_open_bytes']['improved_pairs'],
            'opening_wall_reduction_seconds': g['metrics']['opening_wall_seconds']['paired_reduction_median'],
            'release_allocator_baseline_median': g['metrics']['allocator_release_delta_bytes']['baseline_median'],
            'release_allocator_candidate_median': g['metrics']['allocator_release_delta_bytes']['candidate_median'],
        } for g in independently_derived_summary]
        report['rss_pre_open_range_bytes'] = [min(r['process_max_rss_before_bytes'] for r in observations),
                                               max(r['process_max_rss_before_bytes'] for r in observations)]

    report['checks'] = dict(checks)
    report['passed_check_count'] = sum(v['passed'] for v in checks.values())
    report['failed_check_count'] = len(report['failures'])
    report['passed'] = not report['failures']
    evidence_names = ['manifest.json', 'fixture-manifest.json', 'commands.jsonl']
    if not args.static_only:
        evidence_names += ['observations.jsonl', 'pairs.json', 'summary.json', 'completion.json']
    report['audited_file_sha256'] = {name: file_sha(EVIDENCE / name) for name in evidence_names}
    report['audit_script_sha256'] = file_sha(Path(__file__))
    output = Path('/tmp/illiquid-auxiliary-audit-aa79' + ('-provenance' if args.static_only else '') + '.json')
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'passed': report['passed'], 'checks': report['passed_check_count'],
                      'failures': report['failures'], 'output': str(output)}, indent=2))
    raise SystemExit(0 if report['passed'] else 1)


if __name__ == '__main__':
    main()
