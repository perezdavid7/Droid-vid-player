
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mpeg_recovery_jump.dart';
import 'recovery_segments.dart';

/// Runs each detected MPEG byte range as a separate, bounded FFmpeg task.
/// Small-buffer copies avoid loading multi-GB sources into Dart memory.
/// The original is read-only, and all outputs are written under new names.
class MpegAutoRecovery {
  static Future<MpegAutoRegionResult> recoverRegion({
    required String sourcePath,
    required MpegFullScanRegion region,
    required String directory,
    required String stem,
    required bool Function() isCancelled,
    void Function(String)? onProgress,
    void Function(int? sessionId)? onSession,
  }) async {
    final tempDirectory = await getTemporaryDirectory();
    final temp = File(p.join(tempDirectory.path, '$stem.source_part.mpg'));
    final log = File(p.join(directory, '$stem.log.txt'));
    final pattern = p.join(directory, '$stem.segment_%05d.mkv');
    final existing = await RecoverySegments.list(directory, stem);
    if (existing.isNotEmpty || await temp.exists()) {
      throw StateError('This recovery job already has output files.');
    }
    var copied = 0;
    try {
      await temp.create(exclusive: true);
      final source = await File(sourcePath).open(mode: FileMode.read);
      final target = await temp.open(mode: FileMode.writeOnly);
      try {
        await source.setPosition(region.startByte);
        while (copied < region.length) {
          if (isCancelled()) {
            return const MpegAutoRegionResult(segments: 0, completed: false);
          }
          final amount = math.min(1024 * 1024, region.length - copied);
          final chunk = await source.read(amount);
          if (chunk.isEmpty) break;
          await target.writeFrom(chunk);
          copied += chunk.length;
          if (copied % (32 * 1024 * 1024) < chunk.length) {
            onProgress?.call('Preparing byte range: '
                '${(copied / region.length * 100).toStringAsFixed(0)}%');
          }
        }
        await target.flush();
      } finally {
        await target.close();
        await source.close();
      }
      if (isCancelled()) {
        return const MpegAutoRegionResult(segments: 0, completed: false);
      }
      if (copied < region.length) {
        throw StateError('Source ended before the selected range was copied.');
      }
      onProgress?.call('Decoding this region into separate MKV segments…');
      final finished = Completer<FFmpegSession>();
      final session = await FFmpegKit.executeWithArgumentsAsync([
        '-hide_banner', '-nostdin', '-loglevel', 'warning',
        '-fflags', '+genpts+discardcorrupt',
        '-err_detect', 'ignore_err',
        '-threads', '2',
        '-f', 'mpeg', '-i', temp.path,
        '-map', region.stream,
        '-map', '0:a:0?',
        '-sn', '-dn',
        ...RecoverySegments.args(
          inputArgs: const [],
          pattern: pattern,
          legacyMpeg: true,
        ),
      ], (done) {
        if (!finished.isCompleted) finished.complete(done);
      });
      final sessionId = session.getSessionId();
      onSession?.call(sessionId);
      if (isCancelled() && sessionId != null) {
        await FFmpegKit.cancel(sessionId);
      }
      FFmpegSession result;
      try {
        result = await finished.future.timeout(const Duration(hours: 2));
      } on TimeoutException {
        if (sessionId != null) await FFmpegKit.cancel(sessionId);
        throw StateError('Region encoder timed out; earlier clips were kept.');
      }
      final code = await result.getReturnCode();
      final logs = await result.getLogsAsString();
      await log.writeAsString(
        'MPEG automatic recovery region\n'
        'Source: $sourcePath\n'
        'Bytes: ${region.startByte}..${region.endByte}\n'
        'Approximate file position: ${region.fromPercent}%–'
        '${region.throughPercent}%\n'
        'Validated samples: ${region.playableSamples}\n'
        'Video track: ${region.stream}\n'
        'FFmpeg exit: $code\n'
        'Cancelled: ${isCancelled()}\n\n'
        '${logs.length > 50000 ? logs.substring(logs.length - 50000) : logs}',
        flush: true,
      );
      final segments = await RecoverySegments.list(directory, stem);
      return MpegAutoRegionResult(
        segments: segments.length,
        completed: ReturnCode.isSuccess(code) && !isCancelled(),
      );
    } finally {
      onSession?.call(null);
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (_) {
          // On Android a locked temp may be cleaned up by the OS later.
        }
      }
    }
  }
}

class MpegAutoRegionResult {
  final int segments;
  final bool completed;
  const MpegAutoRegionResult({
    required this.segments,
    required this.completed,
  });
}
