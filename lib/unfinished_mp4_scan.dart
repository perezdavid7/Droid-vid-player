import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mpeg_full_scan.dart';

class Mp4RawRegion {
  final int startByte;
  final int endByte;
  final String inputFormat;
  final String extension;
  const Mp4RawRegion(this.startByte, this.endByte,
      this.inputFormat, this.extension);
}

class UnfinishedMp4Result {
  final List<Mp4RawRegion> regions;
  final String explanation;
  const UnfinishedMp4Result(this.regions, this.explanation);
}

class _Mp4DataRange {
  final int start;
  final int end;
  const _Mp4DataRange(this.start, this.end);
}

class _RawMarkers {
  int mpeg4Vol = 0;
  int mpeg4Vop = 0;
  int mpeg2Sequence = 0;
  int mpeg2Picture = 0;
  int h264Sps = 0;
  int h264Pps = 0;
  int h264Idr = 0;
  int h265Vps = 0;
  int h265Sps = 0;
  int h265Pps = 0;
  int h265Irap = 0;
  int? firstVol;
  int? firstVop;

  void inspect(List<int> bytes, int position, int absolute) {
    if (bytes[position] != 0 || bytes[position + 1] != 0 ||
        bytes[position + 2] != 1) {
      return;
    }
    final marker = bytes[position + 3];
    if (marker >= 0x20 && marker <= 0x2f) {
      mpeg4Vol++;
      firstVol ??= absolute;
    }
    if (marker == 0xb6) {
      mpeg4Vop++;
      firstVop ??= absolute;
    }
    if (marker == 0xb3) mpeg2Sequence++;
    if (marker == 0x00) mpeg2Picture++;

    // Start codes in MP4 are uncommon for AVC/HEVC: those codecs
    // normally use length-prefixed NAL units requiring a separate parser.
    if (position + 4 >= bytes.length || (marker & 0x80) != 0) return;
    if ((marker & 0x1f) == 7) h264Sps++;
    if ((marker & 0x1f) == 8) h264Pps++;
    if ((marker & 0x1f) == 5) h264Idr++;
    final hevc = (marker >> 1) & 0x3f;
    if ((bytes[position + 4] & 7) == 0) return;
    if (hevc == 32) h265Vps++;
    if (hevc == 33) h265Sps++;
    if (hevc == 34) h265Pps++;
    if (hevc == 19 || hevc == 20 || hevc == 21) h265Irap++;
  }

  List<(String, String)> get probeFormats {
    final result = <(String, String)>[];
    if (mpeg4Vop >= 2) result.add(('m4v', '.m4v'));
    if (mpeg2Sequence >= 1 && mpeg2Picture >= 3) {
      result.add(('mpegvideo', '.m2v'));
    }
    if (h264Sps > 0 && h264Pps > 0 && h264Idr > 0) {
      result.add(('h264', '.h264'));
    }
    if (h265Vps > 0 && h265Sps > 0 && h265Pps > 0 &&
        h265Irap > 0) {
      result.add(('hevc', '.h265'));
    }
    return result;
  }
}

/// Experimental salvage for MP4 files whose media-data box survived but
/// whose movie index (moov) is absent. It does NOT invent sample tables,
/// codec extradata, or promise that compressed bytes are decodable.
///
/// Works best with MPEG-4 Visual elementary streams (VOP start codes),
/// including some earlier Droid Vid Player Deep Recovery intermediates.
/// H.264/HEVC length-prefixed MP4 samples often cannot be decoded without
/// the missing avcC/hvcC codec configuration and are reported as such.
class UnfinishedMp4Scan {
  static const int _mib = 1024 * 1024;
  static const int _maxRangeBytes = 128 * _mib;
  static const int _maxProbes = 128;

  static int _be32(List<int> b, int at) =>
      (b[at] << 24) | (b[at + 1] << 16) |
      (b[at + 2] << 8) | b[at + 3];

  static Future<List<_Mp4DataRange>> _mdatRanges(
      File file, int total, bool Function() isCancelled) async {
    final data = <_Mp4DataRange>[];
    final handle = await file.open();
    try {
      var offset = 0;
      for (var i = 0; i < 2048 && offset + 8 <= total; i++) {
        if (isCancelled()) throw const MpegScanCancelled();
        await handle.setPosition(offset);
        final header = await handle.read(16);
        if (header.length < 8) break;
        final kind = String.fromCharCodes(header.sublist(4, 8));
        if (!RegExp(r'^[a-zA-Z0-9 ]{4}$').hasMatch(kind)) break;
        var bytes = _be32(header, 0);
        var headerLength = 8;
        if (bytes == 1) {
          if (header.length < 16) break;
          bytes = 0;
          for (var n = 8; n < 16; n++) {
            bytes = (bytes << 8) | header[n];
          }
          headerLength = 16;
        } else if (bytes == 0) {
          bytes = total - offset;
        }
        if (bytes < headerLength || bytes > total - offset) break;
        if (kind == 'mdat' && bytes > headerLength) {
          data.add(_Mp4DataRange(offset + headerLength,
              offset + bytes));
        }
        offset += bytes;
      }
    } finally {
      await handle.close();
    }
    return data;
  }

  static Future<_RawMarkers> _inspectRange(File file, int start, int end, {
    required bool Function() isCancelled,
    void Function(double)? onByteProgress,
    required int totalBytes,
  }) async {
    final markers = _RawMarkers();
    var consumed = start;
    var tail = <int>[];
    await for (final chunk in file.openRead(start, end)) {
      if (isCancelled()) throw const MpegScanCancelled();
      final data = <int>[...tail, ...chunk];
      final base = consumed - tail.length;
      final scanCount = math.max(0, data.length - 5);
      for (var i = 0; i < scanCount; i++) {
        markers.inspect(data, i, base + i);
      }
      tail = data.sublist(scanCount);
      consumed += chunk.length;
      onByteProgress?.call(consumed / totalBytes);
    }
    for (var i = 0; i + 4 < tail.length; i++) {
      markers.inspect(tail, i, end - tail.length + i);
    }
    return markers;
  }

  static Future<bool> _decodedFrames(
      String filePath, String format, bool Function() isCancelled) async {
    if (isCancelled()) throw const MpegScanCancelled();
    final completed = Completer<void>();
    int? id;
    Timer? timer;
    try {
      final session = await FFmpegKit.executeWithArgumentsAsync([
        '-hide_banner', '-nostdin', '-loglevel', 'info',
        '-fflags', '+genpts+discardcorrupt',
        '-err_detect', 'ignore_err',
        '-threads', '1', '-f', format, '-i', filePath,
        '-map', '0:v:0', '-an', '-sn', '-dn',
        '-vf', 'showinfo', '-frames:v', '3',
        '-f', 'null', '-',
      ], (_) {
        if (!completed.isCompleted) completed.complete();
      });
      id = session.getSessionId();
      final activeId = id;
      timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (isCancelled() && activeId != null) {
          unawaited(FFmpegKit.cancel(activeId));
        }
      });
      await completed.future.timeout(const Duration(seconds: 25));
      if (isCancelled()) throw const MpegScanCancelled();
      final logs = await session.getLogsAsString();
      return RegExp(r'showinfo.*\bn:\s*\d+')
          .allMatches(logs).length >= 2;
    } on MpegScanCancelled {
      rethrow;
    } on TimeoutException {
      if (id != null) await FFmpegKit.cancel(id);
      return false;
    } catch (_) {
      if (isCancelled()) throw const MpegScanCancelled();
      return false;
    } finally {
      timer?.cancel();
    }
  }

  static Future<UnfinishedMp4Result> scan(String path, {
    required bool Function() isCancelled,
    void Function(double)? onByteProgress,
    void Function(int completed, int total)? onProbeProgress,
  }) async {
    final file = File(path);
    final size = await file.length();
    final mdats = await _mdatRanges(file, size, isCancelled);
    if (mdats.isEmpty) {
      onByteProgress?.call(1);
      return const UnfinishedMp4Result([],
          'No valid top-level mdat box was found. Raw MP4 recovery '
          'cannot be started from this source.');
    }

    final windows = <_Mp4DataRange>[];
    for (final region in mdats) {
      var offset = region.start;
      while (offset < region.end) {
        final end = math.min(region.end, offset + _maxRangeBytes);
        windows.add(_Mp4DataRange(offset, end));
        offset = end;
      }
    }
    final counts = <_RawMarkers>[];
    for (final range in windows) {
      if (isCancelled()) throw const MpegScanCancelled();
      counts.add(await _inspectRange(file, range.start, range.end,
        isCancelled: isCancelled,
        totalBytes: size,
        onByteProgress: onByteProgress));
    }
    onByteProgress?.call(1);

    final proposals = <(int, String, String)>[];
    var totalVop = 0, totalVol = 0;
    var totalH264 = 0, totalH265 = 0;
    for (var i = 0; i < windows.length; i++) {
      final markers = counts[i];
      totalVop += markers.mpeg4Vop;
      totalVol += markers.mpeg4Vol;
      totalH264 += markers.h264Sps;
      totalH265 += markers.h265Sps;
      for (final (format, extension) in markers.probeFormats) {
        proposals.add((i, format, extension));
      }
    }
    if (proposals.length > _maxProbes) {
      proposals.removeRange(_maxProbes, proposals.length);
    }
    onProbeProgress?.call(0, proposals.length);

    final tempFolder = await getTemporaryDirectory();
    final candidates = <Mp4RawRegion>[];
    var completed = 0;
    for (final (index, format, extension) in proposals) {
      if (isCancelled()) throw const MpegScanCancelled();
      final region = windows[index];
      // A VOL header is preferable for MPEG-4 Visual, if present in
      // this bounded window. Without codec headers the decoder may fail.
      final start = format == 'm4v'
          ? (counts[index].firstVol ??
              math.max(region.start,
                  (counts[index].firstVop ?? region.start) - 64 * 1024))
          : region.start;
      if (region.end - start < 64 * 1024) {
        completed++;
        onProbeProgress?.call(completed, proposals.length);
        continue;
      }
      final temp = File(p.join(tempFolder.path,
          'droid_raw_mp4_${DateTime.now().microsecondsSinceEpoch}'
          '_$completed$extension'));
      try {
        final end = math.min(region.end, start + 24 * _mib);
        await MpegFullScan.copyByteRange(file, temp, start, end,
            isCancelled: isCancelled);
        if (await _decodedFrames(temp.path, format, isCancelled)) {
          candidates.add(Mp4RawRegion(start, region.end, format, extension));
        }
      } finally {
        try {
          if (await temp.exists()) await temp.delete();
        } catch (_) {}
      }
      completed++;
      onProbeProgress?.call(completed, proposals.length);
    }

    return UnfinishedMp4Result(candidates,
        'Found ${mdats.length} intact mdat box(es) and inspected '
        'all ${windows.length} bounded media-data window(s). '
        'MPEG-4 Visual markers: $totalVol VOL, $totalVop VOP; '
        'Annex-B candidate SPS: H.264=$totalH264, H.265=$totalH265. '
        '${candidates.length} raw video window(s) decoded enough '
        'frames to attempt extraction. This experimental scanner '
        'recovers video only, with approximate timing and no audio. '
        'A missing moov box may also remove essential codec details; '
        'length-prefixed H.264/H.265 samples need a separate conversion '
        'and may not be recoverable without codec configuration.');
  }
}
