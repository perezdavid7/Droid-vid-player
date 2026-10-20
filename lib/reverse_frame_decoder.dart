import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_session.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Bounded reverse-frame decoder, separate from the ExoPlayer playback engine.
/// FFmpeg decodes a short span FORWARD; the UI displays those decoded frames
/// in reverse sequence. No timestamp jumps are used to animate rewind.
///
/// Experimental limitations: thumbnails are silent at 640 px / 12 fps;
/// codec seek accuracy and background decode throughput are file-dependent.
class ReverseFrameBatch {
  final Duration start;
  final Duration end;
  final int framesPerSecond;
  final List<Uint8List> images;

  const ReverseFrameBatch({
    required this.start,
    required this.end,
    required this.framesPerSecond,
    required this.images,
  });

  Duration positionFor(int index) {
    final proposed = start + Duration(
      milliseconds: ((index + 0.5) * 1000 / framesPerSecond).round(),
    );
    return proposed > end ? end : proposed;
  }
}

class ReverseFrameDecoder {
  static const int fps = 12;
  static const int chunkMillis = 2000;
  bool _closed = false;
  int? _sessionId;
  Directory? _workRoot;
  int _chunkNumber = 0;

  Future<ReverseFrameBatch?> decode({
    required String sourcePath,
    required Duration before,
  }) async {
    if (_closed || before <= Duration.zero) return null;
    final endMs = before.inMilliseconds;
    final startMs = (endMs - chunkMillis).clamp(0, endMs);
    final spanMs = endMs - startMs;
    if (spanMs <= 0) return null;
    _workRoot ??= await Directory(
      p.join((await getTemporaryDirectory()).path,
          'droid_reverse_${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true);
    if (_closed) return null;
    final folder = await Directory(
      p.join(_workRoot!.path, 'chunk_${_chunkNumber++}'),
    ).create(recursive: true);
    final output = p.join(folder.path, 'frame_%04d.jpg');
    try {
      final completed = Completer<FFmpegSession>();
      // Bound decoded duration and resolution: never extract an entire movie.
      final args = <String>[
        '-hide_banner', '-nostdin', '-loglevel', 'error',
        '-y', '-ss', (startMs / 1000).toStringAsFixed(3),
        '-i', sourcePath,
        '-t', (spanMs / 1000).toStringAsFixed(3),
        '-map', '0:v:0', '-an', '-sn', '-dn',
        '-vf', 'fps=$fps,scale=640:-2:force_original_aspect_ratio=decrease',
        '-c:v', 'mjpeg', '-q:v', '5', '-f', 'image2', output,
      ];
      final session = await FFmpegKit.executeWithArgumentsAsync(
        args,
        (finished) {
          if (!completed.isCompleted) completed.complete(finished);
        },
      );
      _sessionId = session.getSessionId();
      try {
        await completed.future.timeout(const Duration(seconds: 14));
      } on TimeoutException {
        if (_sessionId != null) {
          await FFmpegKit.cancel(_sessionId);
        }
      } finally {
        _sessionId = null;
      }
      if (_closed) return null;
      final files = folder.listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (files.isEmpty) return null;
      final frames = <Uint8List>[];
      for (final file in files.take(fps * 3)) {
        if (_closed) return null;
        frames.add(await file.readAsBytes());
      }
      if (frames.isEmpty || _closed) return null;
      return ReverseFrameBatch(
        start: Duration(milliseconds: startMs),
        end: before,
        framesPerSecond: fps,
        images: frames,
      );
    } finally {
      try {
        if (await folder.exists()) await folder.delete(recursive: true);
      } catch (_) {
        // Temporary cache cleanup is best-effort.
      }
    }
  }

  Future<void> dispose() async {
    _closed = true;
    final id = _sessionId;
    if (id != null) {
      try {
        await FFmpegKit.cancel(id).timeout(const Duration(seconds: 4));
      } catch (_) {
        // A native decoder can still be shutting down.
      }
    }
    final root = _workRoot;
    if (root != null) {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {
        // Cache is temporary; next cleanup can remove it.
      }
    }
  }
}
