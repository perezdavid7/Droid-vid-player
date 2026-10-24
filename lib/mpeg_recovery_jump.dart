import 'dart:io';
import 'dart:math' as math;
import 'dart:async';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

/// Finds an MPEG Program Stream pack boundary after a user-chosen physical
/// file position. This uses source BYTES, never damaged source timestamps.
/// No media is copied, moved, removed, or decoded by this scanner.
class MpegRecoveryJump {
  static const int _windowBytes = 16 * 1024 * 1024;
  static const int _chunkBytes = 256 * 1024;

  static Future<MpegJumpResult> locate(
    String path, {
    required int percent,
    int extraBytes = 0,
  }) async {
    if (percent < 0 || percent >= 100) {
      throw ArgumentError.value(percent, 'percent', 'Must be 0–99');
    }
    final file = File(path);
    final size = await file.length();
    if (size < 1024 * 1024) {
      throw StateError('The source is too small for byte-jump recovery.');
    }
    final approximate = (size ~/ 100 * percent +
        ((size % 100) * percent ~/ 100) + extraBytes).clamp(0, size - 1);
    final stop = math.min(size, approximate + _windowBytes);
    final input = await file.open();
    var cursor = approximate;
    var trailing = <int>[];
    try {
      await input.setPosition(approximate);
      while (cursor < stop) {
        final bytes = await input.read(math.min(_chunkBytes, stop - cursor));
        if (bytes.isEmpty) break;
        final window = <int>[...trailing, ...bytes];
        final base = cursor - trailing.length;
        for (var i = 0; i + 8 < window.length; i++) {
          if (window[i] != 0 || window[i + 1] != 0 ||
              window[i + 2] != 1 || window[i + 3] != 0xba) {
            continue;
          }
          // MPEG-2 PS pack headers begin with '01..0100'; MPEG-1
          // pack headers begin with '0010'. Filter random false matches.
          final header = window[i + 4];
          final mpeg2 = header & 0xc4 == 0x44;
          final mpeg1 = header & 0xf0 == 0x20;
          if (mpeg2 || mpeg1) {
            final boundary = base + i;
            if (boundary >= approximate) {
              return MpegJumpResult(
                sourceBytes: size,
                percent: percent,
                requestedByte: approximate,
                alignedByte: boundary,
              );
            }
          }
        }
        cursor += bytes.length;
        trailing = window.length < 8
            ? window : window.sublist(window.length - 8);
      }
    } finally {
      await input.close();
    }
    throw StateError('No MPEG program-stream pack boundary was found '
        'within 16 MB after the selected $percent% position. '
        'Try a different percentage; no recovery files were created.');
  }

  /// A short video decode is required before starting full-length recovery.
  /// A damaged program stream may advertise several Video: none tracks.
  static Future<MpegDecodedStart> findDecodableStart(
    String path, {
    required int percent,
    void Function(String)? onProgress,
  }) async {
    const offsets = <int>[
      0,
      32 * 1024 * 1024,
      128 * 1024 * 1024,
    ];
    final diagnostics = <String>[];
    for (final extra in offsets) {
      MpegJumpResult jump;
      try {
        jump = await locate(path, percent: percent, extraBytes: extra);
      } catch (error) {
        diagnostics.add('Boundary scan +${extra ~/ 1048576} MiB: $error');
        continue;
      }
      for (var index = 0; index < 4; index++) {
        final stream = '0:v:$index';
        onProgress?.call('Testing video stream ${index + 1}/4 '
            'near $percent% + ${extra ~/ 1048576} MiB. '
            'No recovery data is being saved yet.');
        final result = await _testFrames(path, jump.alignedByte, stream);
        if (result.ok) {
          return MpegDecodedStart(jump: jump, stream: stream);
        }
        diagnostics.add('At byte ${jump.alignedByte} / $stream: '
            '${result.reason}');
      }
    }
    throw StateError('No decodable video stream found near '
        '$percent% (also tested +32 and +128 MiB). '
        'No video segments were created. Try 50% or 70%. '
        'Probe results: ${diagnostics.take(5).join(" | ")}');
  }


  /// Samples the entire physical file at each 1% byte position.
  /// Positive samples prove short playable spans, not every intervening byte.
  static Future<List<MpegFullScanRegion>> scanEntireFile(
    String path, {
    required bool Function() isCancelled,
    void Function(double fraction, String message)? onProgress,
  }) async {
    final bytes = await File(path).length();
    if (bytes < 1024 * 1024) {
      throw StateError('MPEG source is too small to scan.');
    }
    final hits = <({int percent, int byte, String stream})>[];
    String? preferredStream;
    for (var percent = 0; percent < 100; percent++) {
      if (isCancelled()) return [];
      onProgress?.call(percent / 100,
          'Scanning $percent% of source bytes · ${hits.length} playable samples.');
      try {
        final jump = await locate(path, percent: percent);
        final candidates = <String>[
          if (preferredStream != null) preferredStream,
          for (var i = 0; i < 4; i++) '0:v:$i',
        ].toSet();
        for (final stream in candidates) {
          if (isCancelled()) return [];
          final result = await _testFrames(
            path, jump.alignedByte, stream,
            timeout: const Duration(seconds: 8),
          );
          if (result.ok) {
            hits.add((percent: percent, byte: jump.alignedByte, stream: stream));
            preferredStream = stream;
            break;
          }
        }
      } catch (_) {
        // A failed position never stops the remaining scan.
      }
      onProgress?.call((percent + 1) / 100,
          'Scanned ${percent + 1}% · ${hits.length} playable samples.');
    }
    if (isCancelled() || hits.isEmpty) return [];
    final regions = <MpegFullScanRegion>[];
    var start = 0;
    for (var i = 1; i <= hits.length; i++) {
      final split = i == hits.length ||
          hits[i].percent != hits[i - 1].percent + 1 ||
          hits[i].stream != hits[i - 1].stream;
      if (!split) continue;
      final first = hits[start];
      final last = hits[i - 1];
      final endPercent = math.min(100, last.percent + 1);
      final endByte = math.min(bytes, bytes ~/ 100 * endPercent +
          (bytes % 100) * endPercent ~/ 100);
      if (endByte > first.byte) {
        regions.add(MpegFullScanRegion(
          fromPercent: first.percent,
          throughPercent: endPercent,
          startByte: first.byte,
          endByte: endByte,
          stream: first.stream,
          playableSamples: i - start,
        ));
      }
      start = i;
    }
    return regions;
  }

  static Future<({bool ok, String reason})> _testFrames(
      String path, int offset, String stream, {
        Duration timeout = const Duration(seconds: 20),
      }) async {
    final done = Completer<void>();
    int? sessionId;
    try {
      final session = await FFmpegKit.executeWithArgumentsAsync([
        '-hide_banner', '-nostdin', '-loglevel', 'info',
        '-fflags', '+genpts+discardcorrupt',
        '-err_detect', 'ignore_err',
        '-probesize', '16000000',
        '-analyzeduration', '20000000',
        '-max_probe_packets', '20000',
        '-threads', '1',
        '-skip_initial_bytes', '$offset',
        '-f', 'mpeg', '-i', path,
        '-map', stream,
        '-an', '-sn', '-dn',
        '-vf', 'showinfo',
        '-frames:v', '3',
        '-f', 'null', '-',
      ], (finished) {
        if (!done.isCompleted) done.complete();
      });
      sessionId = session.getSessionId();
      await done.future.timeout(timeout);
      final code = await session.getReturnCode();
      final logs = await session.getLogsAsString();
      final decoded = RegExp(r'showinfo.*\bn:\s*\d+').hasMatch(logs);
      if (ReturnCode.isSuccess(code) && decoded) {
        return (ok: true, reason: 'decoded frames');
      }
      final lines = logs.split('\n')
          .where((line) => line.contains('Decoder') ||
              line.contains('codec parameters') ||
              line.contains('Stream map') ||
              line.contains('Output file') ||
              line.contains('Error'))
          .toList();
      return (ok: false, reason: lines.isEmpty
          ? 'No video frames decoded'
          : lines.last.trim().substring(
              0, math.min(lines.last.trim().length, 120)));
    } on TimeoutException {
      if (sessionId != null) await FFmpegKit.cancel(sessionId);
      return (ok: false, reason: 'Decode probe timeout');
    } catch (error) {
      return (ok: false, reason: '$error');
    }
  }
}

class MpegDecodedStart {
  final MpegJumpResult jump;
  final String stream;
  const MpegDecodedStart({required this.jump, required this.stream});
}

class MpegJumpResult {
  final int sourceBytes;
  final int percent;
  final int requestedByte;
  final int alignedByte;
  const MpegJumpResult({
    required this.sourceBytes,
    required this.percent,
    required this.requestedByte,
    required this.alignedByte,
  });
}

 
/// A byte range with independently verified playable probe positions.
/// Boundaries are estimates; recovered clips still require review.
class MpegFullScanRegion {
  final int fromPercent;
  final int throughPercent;
  final int startByte;
  final int endByte;
  final String stream;
  final int playableSamples;

  const MpegFullScanRegion({
    required this.fromPercent,
    required this.throughPercent,
    required this.startByte,
    required this.endByte,
    required this.stream,
    required this.playableSamples,
  });

  int get length => endByte - startByte;
}
