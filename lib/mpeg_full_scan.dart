import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A decodable MPEG-PS region bounded by source bytes (not timestamps).
class MpegRecoveryRegion {
  final int startByte;
  final int endByte;
  final int sourceBytes;
  final String videoStream;
  const MpegRecoveryRegion({
    required this.startByte,
    required this.endByte,
    required this.sourceBytes,
    required this.videoStream,
  });
  double get startPercent => 100 * startByte / sourceBytes;
  double get endPercent => 100 * endByte / sourceBytes;
  int get length => endByte - startByte;
}

class _MpegScanWindow {
  final int end;
  int? firstPack;
  int packets = 0;
  String? verifiedStream;
  _MpegScanWindow(this.end);
}

/// Reads every input byte, then locally decodes every candidate window.
/// A failed window never stops the remaining 0-100% scan.
class MpegFullScan {
  static const int _mib = 1024 * 1024;
  static const int maxTaskBytes = 256 * _mib;

  static Future<List<MpegRecoveryRegion>> scan(
    String path, {
    required bool Function() isCancelled,
    void Function(double)? onByteProgress,
    void Function(int completed, int total)? onProbeProgress,
  }) async {
    final file = File(path);
    final length = await file.length();
    if (length < _mib) {
      throw StateError('Source is too small for MPEG full-file scanning.');
    }
    // At most about 256 probe windows on multi-GB files.
    final windowBytes = math.max(_mib,
        math.min(16 * _mib, (length / 256).ceil()));
    final windows = List<_MpegScanWindow>.generate(
      (length + windowBytes - 1) ~/ windowBytes,
      (i) => _MpegScanWindow(math.min(length, (i + 1) * windowBytes)),
    );

    var bytesRead = 0;
    var tail = <int>[];
    var lastPercent = -1;
    await for (final chunk in file.openRead(0, length)) {
      if (isCancelled()) throw const MpegScanCancelled();
      final data = <int>[...tail, ...chunk];
      final base = bytesRead - tail.length;
      for (var i = 0; i + 8 < data.length; i++) {
        if (data[i] != 0 || data[i + 1] != 0 ||
            data[i + 2] != 1 || data[i + 3] != 0xba) {
          continue;
        }
        final header = data[i + 4];
        if ((header & 0xc4 != 0x44) && (header & 0xf0 != 0x20)) {
          continue;
        }
        final offset = base + i;
        if (offset < 0 || offset >= length) continue;
        final window = windows[offset ~/ windowBytes];
        window.firstPack ??= offset;
        window.packets++;
      }
      bytesRead += chunk.length;
      tail = data.length <= 8 ? data : data.sublist(data.length - 8);
      final pct = math.min(100, bytesRead * 100 ~/ length);
      if (pct != lastPercent) {
        lastPercent = pct;
        onByteProgress?.call(bytesRead / length);
      }
    }
    onByteProgress?.call(1);

    final candidates = <int>[
      for (var i = 0; i < windows.length; i++)
        if (windows[i].packets >= 2) i,
    ];
    onProbeProgress?.call(0, candidates.length);
    if (candidates.isEmpty) return const [];

    final tempDirectory = await getTemporaryDirectory();
    final probeFile = File(p.join(tempDirectory.path,
        'droid_fullscan_${DateTime.now().microsecondsSinceEpoch}.mpg'));
    String? lastStream;
    try {
      for (var n = 0; n < candidates.length; n++) {
        if (isCancelled()) throw const MpegScanCancelled();
        final window = windows[candidates[n]];
        final start = window.firstPack!;
        // The probe is a bounded copy. Probing the original to EOF would
        // falsely label corrupt bytes as playable when later frames decode.
        final end = math.min(window.end, start + 16 * _mib);
        if (end - start >= 64 * 1024) {
          await copyByteRange(file, probeFile, start, end,
              isCancelled: isCancelled);
          final streams = <String>{};
          if (lastStream != null) {
            streams.add(lastStream);
          }
          streams.addAll({'0:v:0', '0:v:1', '0:v:2', '0:v:3'});
          for (final stream in streams) {
            if (isCancelled()) throw const MpegScanCancelled();
            if (await _decodesThreeFrames(probeFile.path, stream)) {
              window.verifiedStream = stream;
              lastStream = stream;
              break;
            }
          }
        }
        onProbeProgress?.call(n + 1, candidates.length);
      }
    } finally {
      // This is only a generated probe, never the source or saved output.
      try {
        if (await probeFile.exists()) await probeFile.delete();
      } catch (_) {}
    }

    final regions = <MpegRecoveryRegion>[];
    int? begin;
    int? end;
    String? stream;
    int? previousIndex;
    void finishRegion() {
      if (begin != null && end != null && stream != null &&
          end! > begin!) {
        regions.add(MpegRecoveryRegion(
          startByte: begin!, endByte: end!, sourceBytes: length,
          videoStream: stream!,
        ));
      }
      begin = null;
      end = null;
      stream = null;
    }
    for (var i = 0; i < windows.length; i++) {
      final window = windows[i];
      final verified = window.verifiedStream;
      if (verified == null) {
        finishRegion();
        previousIndex = null;
        continue;
      }
      if (begin == null || previousIndex != i - 1 ||
          stream != verified ||
          window.end - begin! > maxTaskBytes) {
        finishRegion();
        begin = window.firstPack!;
        stream = verified;
      }
      end = window.end;
      previousIndex = i;
    }
    finishRegion();
    return regions;
  }

  /// Copy one job with streaming IO; no multi-GB buffers or source edits.
  static Future<void> copyByteRange(
    File source, File destination, int start, int end, {
    required bool Function() isCancelled,
    List<int> prefixBytes = const [],
  }) async {
    final sink = destination.openWrite();
    try {
      if (isCancelled()) throw const MpegScanCancelled();
      if (prefixBytes.isNotEmpty) sink.add(prefixBytes);
      await for (final bytes in source.openRead(start, end)) {
        if (isCancelled()) throw const MpegScanCancelled();
        sink.add(bytes);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  static Future<bool> _decodesThreeFrames(String path, String stream) async {
    final done = Completer<void>();
    int? sessionId;
    try {
      final session = await FFmpegKit.executeWithArgumentsAsync([
        '-hide_banner', '-nostdin', '-loglevel', 'info',
        '-fflags', '+genpts+discardcorrupt',
        '-err_detect', 'ignore_err',
        '-probesize', '16000000',
        '-analyzeduration', '10000000',
        '-threads', '1',
        '-f', 'mpeg', '-i', path,
        '-map', stream, '-an', '-sn', '-dn',
        '-vf', 'showinfo',
        '-frames:v', '3', '-f', 'null', '-',
      ], (_) {
        if (!done.isCompleted) done.complete();
      });
      sessionId = session.getSessionId();
      await done.future.timeout(const Duration(seconds: 20));
      final logs = await session.getLogsAsString();
      // Truncated local samples can exit nonzero after real frames decode.
      return RegExp(r'showinfo.*\bn:\s*\d+')
          .allMatches(logs).length >= 3;
    } on TimeoutException {
      if (sessionId != null) await FFmpegKit.cancel(sessionId);
      return false;
    } catch (_) {
      return false;
    }
  }
}

class MpegScanCancelled implements Exception {
  const MpegScanCancelled();
  @override
  String toString() => 'Full-file scan stopped by user';
}
