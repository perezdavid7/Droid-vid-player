import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mpeg_full_scan.dart';

class Mp4RawRegion {
  final int startByte;
  final int endByte;
  final String inputFormat;
  final String extension;
  final List<int> prefixBytes;
  final String? reconstruction;
  const Mp4RawRegion(this.startByte, this.endByte,
      this.inputFormat, this.extension,
      {this.prefixBytes = const [], this.reconstruction});
}

class UnfinishedMp4Result {
  final List<Mp4RawRegion> regions;
  final String explanation;
  const UnfinishedMp4Result(this.regions, this.explanation);
}

class _VideoBits {
  final List<int> _bytes = [];
  int _pending = 0;
  int _count = 0;

  void put(int value, int bits) {
    for (var shift = bits - 1; shift >= 0; shift--) {
      _pending = (_pending << 1) | ((value >> shift) & 1);
      _count++;
      if (_count == 8) {
        _bytes.add(_pending);
        _pending = 0;
        _count = 0;
      }
    }
  }

  void startCode(int suffix) {
    if (_count != 0) {
      throw StateError('MPEG-4 start code is not byte-aligned');
    }
    put(0x00000100 | suffix, 32);
  }

  List<int> finish() {
    // MPEG-4 Visual byte stuffing: a zero then one bits until aligned.
    final pad = 8 - _count;
    put((1 << (pad - 1)) - 1, pad);
    return List<int>.unmodifiable(_bytes);
  }
}

class _DecodeProbe {
  final int frames;
  final int errors;
  const _DecodeProbe(this.frames, this.errors);
  bool get usable => frames >= 2;
}

class _Mp4DataRange {
  final int start;
  final int end;
  final bool truncated;
  const _Mp4DataRange(this.start, this.end, {this.truncated = false});
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
  int? firstIntraVop;

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
      if (position + 4 < bytes.length &&
          (bytes[position + 4] & 0xc0) == 0) {
        firstIntraVop ??= absolute;
      }
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
/// whose movie index (moov) is absent. It never rewrites the source or
/// recreates the lost sample tables. When MPEG-4 Visual VOPs lack a VOL,
/// it can try explicit synthetic VOL variants, each validated by decoding.
///
/// Works best with MPEG-4 Visual elementary streams (VOP start codes),
/// including some earlier Droid Vid Player Deep Recovery intermediates.
/// H.264/HEVC length-prefixed MP4 samples often cannot be decoded without
/// the missing avcC/hvcC codec configuration and are reported as such.
class UnfinishedMp4Scan {
  static const int _mib = 1024 * 1024;
  static const int _maxRangeBytes = 128 * _mib;
  static const int _maxProbes = 128;
  static const int _maxHeaderTrials = 90;
  static const int _headerProbeBytes = 8 * _mib;
  static const List<(int, int)> _sizes = [
    (640, 480), (720, 480), (1280, 720), (1920, 1080),
    (640, 360), (720, 576), (352, 240), (320, 240),
    (704, 480), (848, 480), (960, 540), (1920, 1088),
  ];
  static const List<int> _timeBases = [30, 25, 30000, 24, 1000, 60];

  /// A deliberately minimal MPEG-4 Visual Simple Profile VOL. These are
  /// trial decoder hints, not a reconstruction of the missing original moov.
  static List<int> _syntheticVol(int width, int height, int timeBase) {
    final b = _VideoBits();
    b.startCode(0x00); // Video object 0.
    b.startCode(0x20); // Video object layer 0.
    b.put(0, 1); // random_accessible_vol
    b.put(1, 8); // Simple profile.
    b.put(1, 1); // video_object_layer_identifier present.
    b.put(1, 4); // version 1.
    b.put(1, 3); // priority 1.
    b.put(1, 4); // square pixel.
    b.put(1, 1); // VOL control present.
    b.put(1, 2); // YUV420 chroma format.
    b.put(1, 1); // low delay.
    b.put(0, 1); // no VBV parameters.
    b.put(0, 2); // rectangular picture.
    b.put(1, 1); // marker.
    b.put(timeBase, 16); // vop_time_increment_resolution.
    b.put(1, 1); // marker.
    b.put(0, 1); // variable VOP rate.
    b.put(1, 1); // marker.
    b.put(width, 13);
    b.put(1, 1); // marker.
    b.put(height, 13);
    b.put(1, 1); // marker.
    b.put(0, 1); // progressive.
    b.put(1, 1); // OBMC disabled.
    b.put(0, 1); // no sprites.
    b.put(0, 1); // 8-bit samples.
    b.put(0, 1); // H.263 quantization.
    b.put(1, 1); // complexity estimation disabled.
    b.put(1, 1); // resync markers disabled.
    b.put(0, 1); // no data partitions.
    b.put(0, 1); // no scalability.
    return b.finish();
  }

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
        if (bytes < headerLength) break;
        if (bytes > total - offset) {
          // Interrupted MP4 recordings can have a declared mdat size
          // that extends beyond the bytes actually written to disk.
          // Scan the surviving payload through EOF, never beyond it.
          if (kind == 'mdat' && total > offset + headerLength) {
            data.add(_Mp4DataRange(offset + headerLength, total,
                truncated: true));
          }
          break;
        }
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

  static Future<_DecodeProbe> _decodedFrames(
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
      final frames = RegExp(r'showinfo.*\bn:\s*\d+')
          .allMatches(logs).length;
      final errors = RegExp(
        r'\b(error|invalid|concealing|corrupt|overread)\b',
        caseSensitive: false,
      ).allMatches(logs).length;
      return _DecodeProbe(frames, errors);
    } on MpegScanCancelled {
      rethrow;
    } on TimeoutException {
      if (id != null) await FFmpegKit.cancel(id);
      return const _DecodeProbe(0, 9999);
    } catch (_) {
      if (isCancelled()) throw const MpegScanCancelled();
      return const _DecodeProbe(0, 9999);
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
    final missingVolWindows = proposals.where((item) =>
        item.$2 == 'm4v' && counts[item.$1].mpeg4Vol == 0).length;
    final perWindowBudget = math.min(
        _sizes.length * _timeBases.length,
        math.max(6, _maxHeaderTrials ~/ math.max(1, missingVolWindows))).toInt();
    final totalTests = (proposals.length +
        math.min(_maxHeaderTrials, missingVolWindows * perWindowBudget)).toInt();
    var testsDone = 0;
    var syntheticTrials = 0;
    var syntheticRecovered = 0;
    final winningGuesses = <String>[];
    onProbeProgress?.call(0, totalTests);

    final tempFolder = await getTemporaryDirectory();
    final candidates = <Mp4RawRegion>[];
    for (var indexInList = 0;
        indexInList < proposals.length; indexInList++) {
      if (isCancelled()) throw const MpegScanCancelled();
      final (index, format, extension) = proposals[indexInList];
      final region = windows[index];
      final markers = counts[index];
      final needsVol = format == 'm4v' && markers.mpeg4Vol == 0;
      final start = needsVol
          ? (markers.firstIntraVop ?? markers.firstVop ?? region.start)
          : format == 'm4v'
              ? (markers.firstVol ??
                  math.max(region.start,
                      (markers.firstVop ?? region.start) - 64 * 1024))
              : region.start;
      if (region.end - start < 64 * 1024) {
        testsDone++;
        onProbeProgress?.call(testsDone, totalTests);
        continue;
      }
      final temp = File(p.join(tempFolder.path,
          'droid_raw_mp4_${DateTime.now().microsecondsSinceEpoch}'
          '_$indexInList$extension'));
      try {
        final probeSize = needsVol ? _headerProbeBytes : 24 * _mib;
        final end = math.min(region.end, start + probeSize);
        await MpegFullScan.copyByteRange(file, temp, start, end,
            isCancelled: isCancelled);
        if (needsVol) {
          final rawFrames = await temp.readAsBytes();
          _DecodeProbe? best;
          List<int>? bestHeader;
          String? bestDescription;
          var localTrials = 0;
          trialLoop:
          for (final timeBase in _timeBases) {
            for (final (width, height) in _sizes) {
              if (localTrials >= perWindowBudget ||
                  syntheticTrials >= _maxHeaderTrials) {
                break trialLoop;
              }
              if (isCancelled()) throw const MpegScanCancelled();
              final header = _syntheticVol(width, height, timeBase);
              final probeBytes = Uint8List(header.length + rawFrames.length);
              probeBytes.setRange(0, header.length, header);
              probeBytes.setRange(
                  header.length, probeBytes.length, rawFrames);
              await temp.writeAsBytes(probeBytes);
              final result =
                  await _decodedFrames(temp.path, format, isCancelled);
              localTrials++;
              syntheticTrials++;
              testsDone++;
              onProbeProgress?.call(testsDone, totalTests);
              if (result.usable &&
                  (best == null || result.errors < best.errors)) {
                best = result;
                bestHeader = header;
                bestDescription = '${width}x$height '
                    'time-base $timeBase '
                    '(${result.errors} decoder error indicators)';
                if (result.errors == 0) break trialLoop;
              }
            }
          }
          if (bestHeader != null) {
            syntheticRecovered++;
            winningGuesses.add(bestDescription!);
            candidates.add(Mp4RawRegion(
                start, region.end, format, extension,
                prefixBytes: bestHeader,
                reconstruction: bestDescription));
          }
        } else {
          final result =
              await _decodedFrames(temp.path, format, isCancelled);
          testsDone++;
          onProbeProgress?.call(testsDone, totalTests);
          if (result.usable) {
            candidates.add(
                Mp4RawRegion(start, region.end, format, extension));
          }
        }
      } finally {
        try {
          if (await temp.exists()) await temp.delete();
        } catch (_) {}
      }
    }
    onProbeProgress?.call(totalTests, totalTests);

    final guessSummary = winningGuesses.isEmpty
        ? ''
        : 'Winning guesses: ${winningGuesses.take(4).join('; ')}. ';
    return UnfinishedMp4Result(candidates,
        'Found ${mdats.length} mdat box(es) '
        '(${mdats.where((range) => range.truncated).length} truncated at EOF) '
        'and inspected '
        'all ${windows.length} bounded media-data window(s). '
        'MPEG-4 Visual markers: $totalVol VOL, $totalVop VOP; '
        'Annex-B candidate SPS: H.264=$totalH264, H.265=$totalH265. '
        '$syntheticTrials locally generated MPEG-4 VOL header trials; '
        '$syntheticRecovered window(s) decoded with candidate headers. '
        '$guessSummary'
        '${candidates.length} raw video window(s) decoded enough '
        'frames to attempt extraction. This experimental scanner '
        'recovers video only, with approximate timing and no audio. '
        'Guessed headers are not original metadata: preview reconstructed '
        'results for correct image dimensions and quality. '
        'A missing moov box may also remove essential codec details; '
        'length-prefixed H.264/H.265 samples need a separate conversion '
        'and may not be recoverable without codec configuration.');
  }
}
