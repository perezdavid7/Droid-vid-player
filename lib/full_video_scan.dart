import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'file_identification.dart';
import 'mpeg_full_scan.dart';
import 'raw_video_scan.dart';

/// A bounded recovery job. Byte ranges are exact; time ranges use the media
/// index and MUST NOT be misrepresented as complete byte-range decoding.
class FullRecoveryJob {
  final int startByte;
  final int endByte;
  final int sourceBytes;
  final double? startSeconds;
  final double? endSeconds;
  final double? totalSeconds;
  final String videoStream;
  final String inputFormat;
  final String inputExtension;
  final bool legacyMpeg;

  const FullRecoveryJob({
    required this.startByte,
    required this.endByte,
    required this.sourceBytes,
    required this.videoStream,
    required this.inputFormat,
    required this.inputExtension,
    required this.legacyMpeg,
    this.startSeconds,
    this.endSeconds,
    this.totalSeconds,
  });

  bool get isByteRange => startSeconds == null;
  int get length => math.max(0, endByte - startByte);
  double get startPercent => sourceBytes == 0 ? 0 :
      100 * startByte / sourceBytes;
  double get endPercent => sourceBytes == 0 ? 100 :
      100 * endByte / sourceBytes;
  String get location => isByteRange
      ? 'Source bytes $startByte–$endByte'
      : 'Indexed playback time '
          '${startSeconds!.toStringAsFixed(1)}–'
          '${endSeconds!.toStringAsFixed(1)} seconds '
          '(byte percentages are estimates)';
}

class FullScanResult {
  final String scanner;
  final String explanation;
  final List<FullRecoveryJob> jobs;
  final bool exactByteRanges;

  const FullScanResult({
    required this.scanner,
    required this.explanation,
    required this.jobs,
    required this.exactByteRanges,
  });
}

/// Each container family gets its own scanning strategy. MPEG-PS and TS
/// produce true bounded byte ranges. Indexed containers first inspect every
/// source byte, then test bounded time seeks: they cannot recover arbitrary
/// orphaned MP4/ASF/EBML packets when metadata is missing.
class FullVideoScan {
  static const _ps = {'.mpg', '.mpeg', '.vob'};
  static const _ts = {'.mts', '.m2ts', '.ts'};
  static const _indexed = {
    '.mp4', '.mov', '.m4v', '.3gp', '.mkv', '.webm',
    '.avi', '.divx', '.wmv', '.asf', '.flv', '.m2v', '.vid',
  };

  static Future<FullScanResult> scan(String path, {
    required bool Function() isCancelled,
    void Function(double)? onByteProgress,
    void Function(int completed, int total)? onProbeProgress,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('The original video cannot be found.');
    }
    final sourceBytes = await file.length();
    if (sourceBytes < 4096) {
      throw StateError('The file is too small to identify video frames.');
    }
    final identification = await identifyFile(path, isCancelled: isCancelled);
    if (isCancelled()) throw const MpegScanCancelled();
    if (identification.isNonVideo) {
      throw StateError('The file header identifies non-video data: '
          '${identification.format}.');
    }

    final extension = p.extension(path).toLowerCase();
    final isPs = _ps.contains(extension) ||
        identification.format == 'MPEG program stream';
    final isTs = _ts.contains(extension) ||
        identification.format == 'MPEG transport stream';
    if (isPs) {
      final found = await MpegFullScan.scan(path,
        isCancelled: isCancelled,
        onByteProgress: onByteProgress,
        onProbeProgress: onProbeProgress);
      return FullScanResult(
        scanner: 'MPEG Program Stream',
        explanation: 'Every byte inspected; independently decoded '
            'MPEG packet windows were grouped into bounded jobs.',
        exactByteRanges: true,
        jobs: [
          for (final region in found)
            FullRecoveryJob(
              startByte: region.startByte, endByte: region.endByte,
              sourceBytes: sourceBytes, videoStream: region.videoStream,
              inputFormat: 'mpeg', inputExtension: '.mpg',
              legacyMpeg: true,
            ),
        ],
      );
    }
    if (isTs) {
      return _scanTransport(path, sourceBytes,
        isCancelled: isCancelled,
        onByteProgress: onByteProgress,
        onProbeProgress: onProbeProgress);
    }
    if (!_indexed.contains(extension) &&
        identification.category != 'video' &&
        identification.category != 'mp4') {
      throw StateError('No supported video container was identified. '
          'Use Advanced Analysis to inspect this file.');
    }
    return _scanIndexed(path, sourceBytes,
      identification: identification,
      isCancelled: isCancelled,
      onByteProgress: onByteProgress,
      onProbeProgress: onProbeProgress);
  }

  static Future<FullScanResult> _scanTransport(String path, int size, {
    required bool Function() isCancelled,
    void Function(double)? onByteProgress,
    void Function(int completed, int total)? onProbeProgress,
  }) async {
    const mib = 1024 * 1024;
    final windowBytes = math.max(mib,
        math.min(16 * mib, (size / 256).ceil()));
    final count = (size + windowBytes - 1) ~/ windowBytes;
    final firstPacket = List<int?>.filled(count, null);
    final matches = List<int>.filled(count, 0);
    var consumed = 0;
    var tail = <int>[];
    var lastPercent = -1;

    await for (final chunk in File(path).openRead()) {
      if (isCancelled()) throw const MpegScanCancelled();
      final data = <int>[...tail, ...chunk];
      final base = consumed - tail.length;
      final limit = math.max(0, data.length - 409);
      for (var i = 0; i < limit; i++) {
        if (data[i] != 0x47) continue;
        int? packetSize;
        for (final packet in const [188, 192, 204]) {
          if (data[i + packet] == 0x47 &&
              data[i + 2 * packet] == 0x47 &&
              data[i] & 0x80 == 0) {
            packetSize = packet;
            break;
          }
        }
        if (packetSize == null) continue;
        final syncAt = base + i;
        // BDAV/M2TS packets contain four time-stamp bytes before 0x47.
        final start = math.max(0,
            syncAt - (packetSize == 192 ? 4 : 0));
        if (start >= size) continue;
        final bucket = start ~/ windowBytes;
        matches[bucket]++;
        firstPacket[bucket] ??= start;
      }
      consumed += chunk.length;
      tail = data.sublist(limit);
      final pct = consumed * 100 ~/ size;
      if (pct != lastPercent) {
        lastPercent = pct;
        onByteProgress?.call(consumed / size);
      }
    }
    onByteProgress?.call(1);

    final candidates = [
      for (var i = 0; i < count; i++)
        if (matches[i] >= 3) i,
    ];
    onProbeProgress?.call(0, candidates.length);
    final verified = List<bool>.filled(count, false);
    final probeFile = File(p.join((await getTemporaryDirectory()).path,
        'droid_ts_probe_${DateTime.now().microsecondsSinceEpoch}.ts'));
    try {
      for (var n = 0; n < candidates.length; n++) {
        if (isCancelled()) throw const MpegScanCancelled();
        final index = candidates[n];
        final start = firstPacket[index]!;
        final end = math.min(size,
            math.min((index + 1) * windowBytes, start + 16 * mib));
        if (end - start >= 64 * 1024) {
          await MpegFullScan.copyByteRange(
            File(path), probeFile, start, end,
            isCancelled: isCancelled,
          );
          verified[index] = await _probeFrames([
            '-f', 'mpegts', '-i', probeFile.path,
          ], isCancelled: isCancelled);
        }
        onProbeProgress?.call(n + 1, candidates.length);
      }
    } finally {
      try {
        if (await probeFile.exists()) await probeFile.delete();
      } catch (_) {}
    }
    final jobs = <FullRecoveryJob>[];
    int? begin;
    var previous = -2;
    void finish(int end) {
      if (begin != null && end > begin!) {
        jobs.add(FullRecoveryJob(
          startByte: begin!, endByte: end, sourceBytes: size,
          videoStream: '0:v:0', inputFormat: 'mpegts',
          inputExtension: '.ts', legacyMpeg: false,
        ));
      }
      begin = null;
    }
    for (var i = 0; i < count; i++) {
      if (!verified[i]) {
        if (begin != null) finish(math.min(size, i * windowBytes));
        previous = -2;
        continue;
      }
      if (begin == null || previous != i - 1 ||
          ((i + 1) * windowBytes - begin!) > 256 * mib) {
        if (begin != null) finish(math.min(size, i * windowBytes));
        begin = firstPacket[i]!;
      }
      previous = i;
    }
    if (begin != null) finish(size);
    return FullScanResult(
      scanner: 'MPEG Transport Stream (TS/MTS/M2TS)',
      explanation: 'Every byte inspected for 188/192/204-byte transport '
          'packets; bounded samples required actual decoded frames.',
      exactByteRanges: true,
      jobs: jobs,
    );
  }

  static Future<FullScanResult> _scanIndexed(String path, int size, {
    required FileIdentification identification,
    required bool Function() isCancelled,
    void Function(double)? onByteProgress,
    void Function(int completed, int total)? onProbeProgress,
  }) async {
    final scanned = await scanRawVideo(path,
      isCancelled: isCancelled, onProgress: onByteProgress);
    if (isCancelled()) throw const MpegScanCancelled();
    final extension = p.extension(path).toLowerCase();
    final scanner = {
      '.mp4': 'MP4 / ISO-BMFF', '.mov': 'MOV / ISO-BMFF',
      '.m4v': 'MP4 / ISO-BMFF', '.3gp': '3GP / ISO-BMFF',
      '.mkv': 'Matroska', '.webm': 'WebM / Matroska',
      '.avi': 'AVI / RIFF', '.divx': 'AVI / RIFF',
      '.wmv': 'WMV / ASF', '.asf': 'ASF',
      '.flv': 'FLV', '.m2v': 'MPEG elementary stream',
      '.vid': 'VID (identified container)',
    }[extension] ?? identification.format;

    double? duration;
    var hasVideo = false;
    try {
      final session = await FFprobeKit.getMediaInformation(path)
          .timeout(const Duration(seconds: 35));
      final info = await session.getMediaInformation();
      if (info != null) {
        duration = double.tryParse(info.getDuration() ?? '');
        hasVideo = info.getStreams().any((stream) =>
            stream.getType() == 'video');
      }
    } catch (_) {
      // Bad container metadata is common in damaged videos.
    }
    if (isCancelled()) throw const MpegScanCancelled();
    if (!hasVideo || duration == null ||
        !duration.isFinite || duration <= 0 || duration > 24 * 3600) {
      // One forward-only attempt can still salvage decodable frames when
      // there is no trustworthy index. It must not be called a verified
      // independent byte region.
      onProbeProgress?.call(0, 0);
      return FullScanResult(
        scanner: scanner,
        explanation: 'All ${scanned.fileSize} source bytes inspected. '
            'No trustworthy indexed video duration was available; '
            'one forward-only decode will be attempted. Missing MP4 moov '
            'metadata or damaged demuxing can still prevent recovery.',
        exactByteRanges: false,
        jobs: [
          FullRecoveryJob(
            startByte: 0, endByte: size, sourceBytes: size,
            startSeconds: 0, endSeconds: 0,
            videoStream: '0:v:0', inputFormat: '',
            inputExtension: extension.isEmpty ? '.bin' : extension,
            legacyMpeg: false,
          ),
        ],
      );
    }
    // Seek probes are samples of playable times, NOT proof that every frame
    // of each interval can be decoded. Keep windows bounded and restartable.
    final durationSeconds = duration;
    final probes = math.max(1, math.min(128, (durationSeconds / 12).ceil()));
    final step = durationSeconds / probes;
    final good = List<bool>.filled(probes, false);
    onProbeProgress?.call(0, probes);
    for (var i = 0; i < probes; i++) {
      if (isCancelled()) throw const MpegScanCancelled();
      final start = i * step;
      good[i] = await _probeFrames([
        '-ss', start.toStringAsFixed(3),
        '-i', path,
        '-t', math.max(2, math.min(6, step)).toStringAsFixed(3),
      ], isCancelled: isCancelled);
      onProbeProgress?.call(i + 1, probes);
    }

    final jobs = <FullRecoveryJob>[];
    int? begin;
    var last = -1;
    void finish(int afterIndex) {
      if (begin == null) return;
      final start = begin! * step;
      final end = math.min(durationSeconds, afterIndex * step);
      if (end > start) {
        jobs.add(FullRecoveryJob(
          startByte: (size * start / durationSeconds).floor(),
          endByte: (size * end / durationSeconds).ceil(),
          sourceBytes: size,
          startSeconds: start, endSeconds: end,
          totalSeconds: durationSeconds,
          videoStream: '0:v:0', inputFormat: '',
          inputExtension: extension.isEmpty ? '.bin' : extension,
          legacyMpeg: false,
        ));
      }
      begin = null;
    }
    for (var i = 0; i < probes; i++) {
      if (!good[i]) {
        finish(i);
        last = -1;
        continue;
      }
      if (begin == null || last != i - 1 ||
          (i + 1 - begin!) * step > 120) {
        finish(i);
        begin = i;
      }
      last = i;
    }
    finish(probes);
    // A damaged time index may make every seek probe fail even though
    // forward decoding from the beginning can salvage some frames.
    if (jobs.isEmpty) {
      jobs.add(FullRecoveryJob(
        startByte: 0, endByte: size, sourceBytes: size,
        startSeconds: 0, endSeconds: 0,
        videoStream: '0:v:0', inputFormat: '',
        inputExtension: extension.isEmpty ? '.bin' : extension,
        legacyMpeg: false,
      ));
    }
    return FullScanResult(
      scanner: scanner,
      explanation: 'All source bytes inspected for structural markers. '
          'Indexed seeks sampled $probes intervals for decodable frames. '
          'Timeline percentages are NOT exact byte positions. '
          'If no seek probe succeeded, one forward-only fallback job '
          'is queued; damaged container metadata can still prevent decoding.',
      exactByteRanges: false,
      jobs: jobs,
    );
  }

  static Future<bool> _probeFrames(List<String> input, {
    required bool Function() isCancelled,
  }) async {
    if (isCancelled()) throw const MpegScanCancelled();
    final done = Completer<void>();
    int? sessionId;
    Timer? cancellationTimer;
    try {
      final session = await FFmpegKit.executeWithArgumentsAsync([
        '-hide_banner', '-nostdin', '-loglevel', 'info',
        '-fflags', '+genpts+discardcorrupt',
        '-err_detect', 'ignore_err',
        '-threads', '1',
        ...input,
        '-map', '0:v:0', '-an', '-sn', '-dn',
        '-vf', 'showinfo', '-frames:v', '3',
        '-f', 'null', '-',
      ], (_) {
        if (!done.isCompleted) done.complete();
      });
      sessionId = session.getSessionId();
      cancellationTimer = Timer.periodic(const Duration(milliseconds: 400),
          (_) {
        if (isCancelled() && sessionId != null) {
          unawaited(FFmpegKit.cancel(sessionId));
        }
      });
      await done.future.timeout(const Duration(seconds: 20));
      if (isCancelled()) throw const MpegScanCancelled();
      final logs = await session.getLogsAsString();
      return RegExp(r'showinfo.*\bn:\s*\d+')
          .allMatches(logs).length >= 2;
    } on MpegScanCancelled {
      rethrow;
    } on TimeoutException {
      if (sessionId != null) await FFmpegKit.cancel(sessionId);
      return false;
    } catch (_) {
      if (isCancelled()) throw const MpegScanCancelled();
      return false;
    } finally {
      cancellationTimer?.cancel();
    }
  }
}
