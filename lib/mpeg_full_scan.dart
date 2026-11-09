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
  /// An exploratory candidate is evidence of video, not verified footage.
  /// Its output must still pass the final decoded-clip verification.
  final bool exploratory;
  final String evidence;
  final String inputFormat;
  const MpegRecoveryRegion({
    required this.startByte,
    required this.endByte,
    required this.sourceBytes,
    required this.videoStream,
    this.exploratory = false,
    this.evidence = '',
    this.inputFormat = 'mpeg',
  });
  double get startPercent => 100 * startByte / sourceBytes;
  double get endPercent => 100 * endByte / sourceBytes;
  int get length => endByte - startByte;
}

class MpegScanReport {
  final List<MpegRecoveryRegion> verified;
  final List<MpegRecoveryRegion> exploratory;
  final int testedWindows;
  final int evidenceWindows;
  final int packHeaders;
  final int videoPackets;
  final int sequenceHeaders;
  final int plausibleSequences;
  final int pictureHeaders;

  const MpegScanReport({
    required this.verified,
    required this.exploratory,
    required this.testedWindows,
    required this.evidenceWindows,
    required this.packHeaders,
    required this.videoPackets,
    required this.sequenceHeaders,
    required this.plausibleSequences,
    required this.pictureHeaders,
  });

  String get explanation =>
      'MPEG-PS: $packHeaders pack headers, $videoPackets video packets, '
      '$sequenceHeaders sequence headers ($plausibleSequences plausible), '
      '$pictureHeaders picture markers. Tested $testedWindows windows; '
      '${verified.length} independently verified regions. '
      '$evidenceWindows windows show possible video evidence; '
      '${exploratory.length} bounded exploratory jobs queued. '
      'Exploratory jobs are NOT verified footage and are saved only if '
      'their output decodes successfully.';
}

class _MpegScanWindow {
  final int end;
  int? firstPack;
  int? firstSequence;
  int? firstEvidence;
  int packets = 0;
  int videoPackets = 0;
  int sequenceHeaders = 0;
  int plausibleSequences = 0;
  int pictureHeaders = 0;
  String? verifiedStream;
  _MpegScanWindow(this.end);

  bool get hasVideoEvidence =>
      (videoPackets > 0 && (pictureHeaders >= 2 || sequenceHeaders > 0)) ||
      (plausibleSequences > 0 && pictureHeaders > 0);

  int get evidenceScore =>
      plausibleSequences * 12 + sequenceHeaders * 3 +
      math.min(pictureHeaders, 40) * 2 + math.min(videoPackets, 20);
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
  }) async => (await scanDetailed(path,
    isCancelled: isCancelled,
    onByteProgress: onByteProgress,
    onProbeProgress: onProbeProgress,
  )).verified;

  /// Independently verified regions plus a small, bounded set of promising
  /// unverified sections. Never equate markers with recovered video.
  static Future<MpegScanReport> scanDetailed(
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
      // Hold 12 bytes back so signatures spanning read boundaries are
      // inspected exactly once, including full MPEG sequence metadata.
      final scanEnd = math.max(0, data.length - 12);
      for (var i = 0; i < scanEnd; i++) {
        if (data[i] != 0 || data[i + 1] != 0 || data[i + 2] != 1) {
          continue;
        }
        final offset = base + i;
        if (offset < 0 || offset >= length) continue;
        final window = windows[offset ~/ windowBytes];
        final marker = data[i + 3];
        if (marker == 0xba) {
          final header = data[i + 4];
          if ((header & 0xc4 == 0x44) || (header & 0xf0 == 0x20)) {
            window.firstPack ??= offset;
            window.packets++;
          }
        } else if (marker >= 0xe0 && marker <= 0xef) {
          window.firstEvidence ??= offset;
          window.videoPackets++;
        } else if (marker == 0xb3) {
          window.firstEvidence ??= offset;
          window.sequenceHeaders++;
          final width = (data[i + 4] << 4) | (data[i + 5] >> 4);
          final height = ((data[i + 5] & 15) << 8) | data[i + 6];
          final aspect = data[i + 7] >> 4;
          final rate = data[i + 7] & 15;
          if (width >= 48 && height >= 48 &&
              aspect >= 1 && aspect <= 4 && rate >= 1 && rate <= 8) {
            window.plausibleSequences++;
            window.firstSequence ??= offset;
          }
        } else if (marker == 0x00) {
          window.firstEvidence ??= offset;
          window.pictureHeaders++;
        }
      }
      bytesRead += chunk.length;
      tail = data.sublist(scanEnd);
      final pct = math.min(100, bytesRead * 100 ~/ length);
      if (pct != lastPercent) {
        lastPercent = pct;
        onByteProgress?.call(bytesRead / length);
      }
    }
    // A short final tail cannot hold a complete sequence header, but may
    // hold packet/picture markers. It cannot create a usable 64 KiB job.
    onByteProgress?.call(1);

    final candidates = <int>[
      for (var i = 0; i < windows.length; i++)
        if (windows[i].packets >= 2) i,
    ];
    onProbeProgress?.call(0, candidates.length);
    // A damaged file may have elementary video markers but few intact packs.
    // In that case we still preserve a bounded number of exploratory areas.

    if (candidates.isNotEmpty) {
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

    final evidence = <int>[
      for (var i = 0; i < windows.length; i++)
        if (windows[i].hasVideoEvidence && windows[i].verifiedStream == null) i,
    ];
    // At most eight extra jobs. Rank by structural evidence, then avoid
    // adjacent windows so a single corrupt area cannot monopolize the queue.
    evidence.sort((a, b) =>
        windows[b].evidenceScore.compareTo(windows[a].evidenceScore));
    final chosen = <int>[];
    for (final index in evidence) {
      if (chosen.length >= 8) break;
      if (chosen.any((other) => (other - index).abs() <= 1)) continue;
      chosen.add(index);
    }
    chosen.sort();
    final exploratory = <MpegRecoveryRegion>[
      for (final index in chosen)
        if (windows[index].end -
            (windows[index].firstPack ??
                windows[index].firstSequence ??
                windows[index].firstEvidence!) >= 64 * 1024)
        MpegRecoveryRegion(
          startByte: windows[index].firstPack ??
              windows[index].firstSequence ??
              windows[index].firstEvidence!,
          endByte: windows[index].end,
          sourceBytes: length,
          videoStream: '0:v:0',
          exploratory: true,
          inputFormat: windows[index].firstPack == null
              ? 'mpegvideo' : 'mpeg',
          evidence: 'video PES=${windows[index].videoPackets}, '
              'sequence=${windows[index].sequenceHeaders}, '
              'plausible sequence=${windows[index].plausibleSequences}, '
              'picture=${windows[index].pictureHeaders}',
        ),
    ];
    return MpegScanReport(
      verified: regions,
      exploratory: exploratory,
      testedWindows: candidates.length,
      evidenceWindows: windows.where((w) => w.hasVideoEvidence).length,
      packHeaders: windows.fold(0, (sum, w) => sum + w.packets),
      videoPackets: windows.fold(0, (sum, w) => sum + w.videoPackets),
      sequenceHeaders: windows.fold(0, (sum, w) => sum + w.sequenceHeaders),
      plausibleSequences: windows.fold(0, (sum, w) => sum + w.plausibleSequences),
      pictureHeaders: windows.fold(0, (sum, w) => sum + w.pictureHeaders),
    );
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
