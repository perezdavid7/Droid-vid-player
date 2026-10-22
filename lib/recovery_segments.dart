import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:path/path.dart' as p;

/// Deep Recovery writes a succession of separately finalized Matroska files.
/// When the FFmpeg process stops unexpectedly, earlier closed segments may
/// survive; the last segment may still be invalid. Nothing is auto-deleted.
class RecoverySegments {
  static const seconds = 90;

  static List<String> args({
    required List<String> inputArgs,
    required String pattern,
    required bool legacyMpeg,
  }) => <String>[
    ...inputArgs,
    if (legacyMpeg) ...[
      '-vf',
      'scale=720:480:force_original_aspect_ratio=decrease,'
      'pad=720:480:(ow-iw)/2:(oh-ih)/2,setsar=1,'
      'setpts=N/(30*TB)',
      '-r', '30', '-fps_mode', 'cfr',
    ] else
      ...['-fps_mode', 'vfr'],
    '-c:v', 'mpeg4', '-q:v', '2',
    '-threads:v', '2', '-pix_fmt', 'yuv420p',
    '-g', '90',
    // Segment at an encoder keyframe near each 90-second boundary.
    '-force_key_frames', 'expr:gte(t,n_forced*90)',
    '-c:a', 'aac', '-b:a', '192k',
    '-af', 'aresample=async=1000:first_pts=0',
    '-avoid_negative_ts', 'make_zero',
    '-max_muxing_queue_size', '1024',
    '-f', 'segment', '-segment_format', 'matroska',
    '-segment_time', '$seconds',
    '-reset_timestamps', '1',
    '-n', pattern,
  ];

  static Future<List<File>> list(String directory, String stem) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return [];
    final files = <File>[];
    await for (final item in dir.list(followLinks: false)) {
      if (item is! File) continue;
      final name = p.basename(item.path);
      if (name.startsWith('$stem.segment_') && name.endsWith('.mkv') &&
          RegExp(r'\.segment_\d{4,}\.mkv$').hasMatch(name)) {
        files.add(item);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// A short decode is only an initial sample check, not a complete test.
  static Future<bool> hasDecodableStart(String path) async {
    final done = Completer<bool>();
    int? sessionId;
    try {
      final session = await FFmpegKit.executeWithArgumentsAsync([
        '-hide_banner', '-nostdin', '-loglevel', 'error',
        '-threads', '2', '-i', path,
        '-map', '0:v:0', '-an', '-frames:v', '2',
        '-f', 'null', '-',
      ], (finished) async {
        final result = await finished.getReturnCode();
        if (!done.isCompleted) done.complete(ReturnCode.isSuccess(result));
      });
      sessionId = session.getSessionId();
      return await done.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      if (sessionId != null) await FFmpegKit.cancel(sessionId);
      return false;
    } catch (_) {
      return false;
    }
  }
}
