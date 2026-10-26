import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mpeg_full_scan.dart';
import 'mp4_vol_profiles.dart';

class Mp4RawRegion {
  final int startByte;
  final int endByte;
  final String inputFormat;
  final String extension;
  final List<int> prefixBytes;
  final String? reconstruction;
  final int? guessedWidth;
  final int? guessedHeight;
  final int? guessedTimeBase;
  const Mp4RawRegion(this.startByte, this.endByte,
      this.inputFormat, this.extension,
      {this.prefixBytes = const [], this.reconstruction,
      this.guessedWidth, this.guessedHeight, this.guessedTimeBase});
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
  int? _previousVop;
  final List<int> intraVops = [];
  final List<int> largeGaps = [];

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
      if (_previousVop != null &&
          absolute - _previousVop! > 3 * 1024 * 1024 &&
          largeGaps.length < 1000) {
        largeGaps.add(absolute);
      }
      _previousVop = absolute;
      if (position + 4 < bytes.length &&
          (bytes[position + 4] & 0xc0) == 0) {
        firstIntraVop ??= absolute;
        if (intraVops.length < 20000) intraVops.add(absolute);
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


class _NalEvidence {
  final int end;
  final int units;
  final int slices;
  final int keyframes;
  final int sps;
  final int pps;
  final int vps;
  const _NalEvidence(this.end, this.units, this.slices,
      this.keyframes, this.sps, this.pps, this.vps);
}

/// A diagnostic-only search: a missing ISO-BMFF sample table means a four-byte
/// NAL length can be mistaken for arbitrary compressed data. We only report
/// sustained, internally consistent chains, never recover them without a
/// successful decoder probe and a codec configuration.
class _SmallMp4Forensics {
  static const _limit = 24 * 1024 * 1024;
  static const _maxNal = 4 * 1024 * 1024;

  static int _be32(Uint8List bytes, int at) =>
      (bytes[at] << 24) | (bytes[at + 1] << 16) |
      (bytes[at + 2] << 8) | bytes[at + 3];

  static _NalEvidence? _run(Uint8List data, int at, bool hevc) {
    var offset = at;
    var count = 0, slices = 0, keys = 0, sps = 0, pps = 0, vps = 0;
    // Limit the work per candidate; do not trust random length fields.
    while (offset + 6 <= data.length && count < 512 &&
        offset - at < 16 * 1024 * 1024) {
      final length = _be32(data, offset);
      if (length < 2 || length > _maxNal ||
          length > data.length - offset - 4) break;
      final header = data[offset + 4];
      if ((header & 0x80) != 0) break;
      if (hevc) {
        final type = (header >> 1) & 0x3f;
        if ((data[offset + 5] & 7) == 0 ||
            !(type <= 35 || type == 39 || type == 40)) break;
        if (type <= 31) slices++;
        if (type >= 16 && type <= 21) keys++;
        if (type == 32) vps++;
        if (type == 33) sps++;
        if (type == 34) pps++;
      } else {
        final type = header & 0x1f;
        if (!(type == 1 || type == 5 || type == 6 ||
            type == 7 || type == 8 || type == 9 ||
            type == 10 || type == 11 || type == 12)) break;
        if (type == 1 || type == 5) slices++;
        if (type == 5) keys++;
        if (type == 7) sps++;
        if (type == 8) pps++;
      }
      count++;
      offset += 4 + length;
    }
    // Guard against a few coincidental byte patterns.
    if (count < 4 || slices < 2 || offset - at < 4096) return null;
    return _NalEvidence(offset, count, slices, keys, sps, pps, vps);
  }

  static Future<String> inspect(File file, int size,
      bool Function() isCancelled) async {
    if (size > _limit) {
      return 'Additional length-prefixed NAL inspection was skipped '
          '(source exceeds the 24 MiB diagnostic limit). ';
    }
    if (isCancelled()) throw const MpegScanCancelled();
    final bytes = await file.readAsBytes();
    final atoms = <String, int>{
      'ftyp': 0, 'moov': 0, 'mdat': 0, 'moof': 0,
      'avcC': 0, 'hvcC': 0,
    };
    var zeros = 0;
    var ff = 0;
    for (var i = 0; i < bytes.length; i++) {
      if ((i & 0x3ffff) == 0 && isCancelled()) {
        throw const MpegScanCancelled();
      }
      if (bytes[i] == 0) zeros++;
      if (bytes[i] == 255) ff++;
      if (i + 8 > bytes.length) continue;
      // A genuine ISO box has a big-endian size preceding its type.
      // Count only plausible-size candidates, even if no top-level chain
      // exists; the surrounding metadata may have been shifted.
      final first = bytes[i + 4];
      if (first != 0x66 && first != 0x6d &&
          first != 0x61 && first != 0x68) continue;
      final kind = String.fromCharCodes(bytes.sublist(i + 4, i + 8));
      if (!atoms.containsKey(kind)) continue;
      final declared = _be32(bytes, i);
      final plausible = declared == 0 || declared == 1 ||
          (declared >= 8 && declared <= bytes.length - i);
      if (plausible) atoms[kind] = atoms[kind]! + 1;
    }
    var avcChains = 0, hevcChains = 0;
    var avcUnits = 0, hevcUnits = 0;
    var avcSlices = 0, hevcSlices = 0;
    var avcSps = 0, avcPps = 0, hevcVps = 0, hevcSps = 0, hevcPps = 0;
    var avcKeys = 0, hevcKeys = 0;
    for (final hevc in [false, true]) {
      for (var i = 0; i + 6 < bytes.length; i++) {
        if ((i & 0x3ffff) == 0 && isCancelled()) {
          throw const MpegScanCancelled();
        }
        // Normal four-byte NAL lengths for short recordings are small
        // compared to 2^32. This screen limits files to 24 MiB.
        if (bytes[i] != 0 || bytes[i + 1] > 64) continue;
        final length = _be32(bytes, i);
        if (length < 2 || length > _maxNal ||
            length > bytes.length - i - 4) continue;
        final found = _run(bytes, i, hevc);
        if (found == null) continue;
        if (hevc) {
          hevcChains++;
          hevcUnits += found.units;
          hevcSlices += found.slices;
          hevcKeys += found.keyframes;
          hevcVps += found.vps;
          hevcSps += found.sps;
          hevcPps += found.pps;
        } else {
          avcChains++;
          avcUnits += found.units;
          avcSlices += found.slices;
          avcKeys += found.keyframes;
          avcSps += found.sps;
          avcPps += found.pps;
        }
        // A recovered run must not be counted again at an inner NAL unit.
        i = found.end - 1;
      }
    }
    final total = bytes.length;
    final zeroPercent = total == 0 ? 0 : (100 * zeros / total).round();
    final ffPercent = total == 0 ? 0 : (100 * ff / total).round();
    final atomText = atoms.entries
        .map((entry) => '${entry.key}=${entry.value}').join(', ');
    final hints = avcChains + hevcChains > 0
        ? 'Possible four-byte length-prefixed NAL sequences detected. '
          'AVC/H.264: $avcChains chain(s), $avcUnits units, '
          '$avcSlices slice(s), $avcKeys keyframe marker(s), '
          '$avcSps SPS / $avcPps PPS. '
          'HEVC/H.265: $hevcChains chain(s), $hevcUnits units, '
          '$hevcSlices slice(s), $hevcKeys keyframe marker(s), '
          '$hevcVps VPS / $hevcSps SPS / $hevcPps PPS. '
          'These patterns are not proof of playable video: '
          'missing codec configuration or sample boundaries can '
          'still prevent decoding. '
        : 'No sustained four-byte length-prefixed AVC/HEVC NAL '
          'sequences were identified either. This does not rule out '
          'other codecs, other length-prefix sizes, fragmented '
          'data, or encrypted content. ';
    final uniform = zeroPercent >= 95 || ffPercent >= 95
        ? 'Most bytes are identical ($zeroPercent% zero, '
          '$ffPercent% 0xFF); the source may contain little '
          'usable compressed video data. '
        : 'Byte fill: $zeroPercent% zero, $ffPercent% 0xFF. ';
    return 'Small-file forensic inspection ($total bytes): '
        'plausible MP4 box signatures: $atomText. '
        '$hints$uniform'
        'No recovery clip is produced solely from signature matches. ';
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
  static const int _maxHeaderTrials = 120;
  static const int _maxSectionBytes = 64 * _mib;
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


  /// Divide long or discontinuous MPEG-4 Visual payloads at actual I-VOP
  /// positions. Each section is non-overlapping; no duplicate exports.
  static List<_Mp4DataRange> _sections(
      _Mp4DataRange range, _RawMarkers markers) {
    final intra = markers.intraVops;
    if (markers.mpeg4Vol > 0 || intra.length < 2) return [range];
    final result = <_Mp4DataRange>[];
    var start = intra.first;
    var gapAt = 0;
    var hasGap = false;
    for (final nextI in intra.skip(1)) {
      while (gapAt < markers.largeGaps.length &&
          markers.largeGaps[gapAt] <= nextI) {
        if (markers.largeGaps[gapAt] > start) hasGap = true;
        gapAt++;
      }
      final enoughBytes = nextI - start >= 256 * 1024;
      if (enoughBytes &&
          (nextI - start >= _maxSectionBytes || hasGap) &&
          range.end - nextI >= 64 * 1024) {
        result.add(_Mp4DataRange(start, nextI));
        start = nextI;
        hasGap = false;
      }
    }
    if (start < range.end) {
      result.add(_Mp4DataRange(start, range.end));
    }
    return result.isEmpty ? [range] : result;
  }

  /// Try a few distinct keyframes if one apparent I-VOP cannot be decoded.
  /// A successful section is still emitted only once.
  static List<int> _startingFrames(
      _Mp4DataRange range, _RawMarkers markers) {
    final possible = markers.intraVops.where((offset) =>
        offset >= range.start && offset + 64 * 1024 < range.end);
    final chosen = <int>[];
    for (final offset in possible) {
      if (chosen.isEmpty || offset - chosen.last >= 1024 * 1024) {
        chosen.add(offset);
        if (chosen.length == 3) break;
      }
    }
    if (chosen.isEmpty && markers.firstVop != null &&
        markers.firstVop! >= range.start &&
        markers.firstVop! + 64 * 1024 < range.end) {
      chosen.add(markers.firstVop!);
    }
    return chosen;
  }

  /// Local verified settings persist across signed updates. A settings write
  /// happens only after a newly recovered clip passes output verification.
  static Future<void> rememberSuccessful(
      String sourcePath, int width, int height, int timeBase) =>
      Mp4VolProfiles.remember(sourcePath, width, height, timeBase);

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
    // An interrupted MP4 can lose the ftyp and mdat box headers while
    // preserving elementary video data. Scan all bytes as raw data in that
    // case; signature hits never count as recovered clips until decoding
    // verifies them.
    final headerlessFallback = mdats.isEmpty;
    final sourceRanges = headerlessFallback
        ? <_Mp4DataRange>[_Mp4DataRange(0, size)]
        : mdats;
    final windows = <_Mp4DataRange>[];
    for (final region in sourceRanges) {
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

    // The source has been inspected from 0–100%. Build independent sections
    // from actual I-VOP markers and large discontinuities, not fixed guesses.
    final proposals = <(_Mp4DataRange, _RawMarkers, String, String)>[];
    var totalVop = 0, totalVol = 0;
    var totalH264 = 0, totalH265 = 0;
    for (var i = 0; i < windows.length; i++) {
      final markers = counts[i];
      totalVop += markers.mpeg4Vop;
      totalVol += markers.mpeg4Vol;
      totalH264 += markers.h264Sps;
      totalH265 += markers.h265Sps;
      for (final (format, extension) in markers.probeFormats) {
        final ranges = format == 'm4v'
            ? _sections(windows[i], markers)
            : [windows[i]];
        for (final section in ranges) {
          if (section.end - section.start >= 64 * 1024) {
            proposals.add((section, markers, format, extension));
          }
        }
      }
    }
    final discovered = proposals.length;
    // Spread bounded probes across the complete file, including its end.
    if (proposals.length > _maxProbes) {
      final all = List.of(proposals);
      proposals.clear();
      for (var i = 0; i < _maxProbes; i++) {
        final at = i * (all.length - 1) ~/ (_maxProbes - 1);
        proposals.add(all[at]);
      }
    }

    List<Mp4VolProfile> remembered;
    try {
      remembered = await Mp4VolProfiles.candidatesFor(path);
    } catch (_) {
      remembered = [];
    }
    final runtimeWinningSettings = <(int, int, int)>[];
    final missingVolSections = proposals.where((item) =>
        item.$3 == 'm4v' && item.$2.mpeg4Vol == 0).length;
    final perSectionBudget = math.min(
        96, math.max(12,
            120 ~/ math.max(1, missingVolSections))).toInt();
    final plannedTests = (proposals.length + _maxHeaderTrials +
        math.min(24, remembered.length) * missingVolSections).toInt();
    var testsDone = 0;
    var syntheticTrials = 0;
    var cachedSelections = 0;
    var alternateStarts = 0;
    final winningGuesses = <String>[];
    onProbeProgress?.call(0, plannedTests);

    final tempFolder = await getTemporaryDirectory();
    final candidates = <Mp4RawRegion>[];
    for (var indexInList = 0;
        indexInList < proposals.length; indexInList++) {
      if (isCancelled()) throw const MpegScanCancelled();
      final (region, markers, format, extension) = proposals[indexInList];
      final needsVol = format == 'm4v' && markers.mpeg4Vol == 0;
      final starts = needsVol
          ? _startingFrames(region, markers)
          : <int>[
              format == 'm4v'
                  ? (markers.firstVol ??
                      math.max(region.start,
                          (markers.firstVop ?? region.start) - 64 * 1024))
                  : region.start,
            ];
      if (starts.isEmpty) {
        testsDone++;
        onProbeProgress?.call(testsDone, plannedTests);
        continue;
      }

      final temp = File(p.join(tempFolder.path,
          'droid_raw_mp4_${DateTime.now().microsecondsSinceEpoch}'
          '_$indexInList$extension'));
      try {
        if (needsVol) {
          _DecodeProbe? best;
          List<int>? bestHeader;
          (int, int, int)? bestSettings;
          String? bestDescription;
          var bestStart = starts.first;
          var bestFromCache = false;
          var localTrials = 0;
          // Guarantee the original 72-setting pass for one continuous
          // section; reserve a few probes for alternate I-VOP starts.
          final firstStartBudget = starts.length == 1
              ? perSectionBudget
              : math.min(72, math.max(6, perSectionBudget - 16)).toInt();
          startLoop:
          for (var startIndex = 0;
              startIndex < starts.length; startIndex++) {
            final startByte = starts[startIndex];
            if (region.end - startByte < 64 * 1024) continue;
            if (localTrials >= perSectionBudget) break;
            if (startIndex > 0) alternateStarts++;
            final end = math.min(region.end,
                startByte + _headerProbeBytes);
            await MpegFullScan.copyByteRange(file, temp, startByte, end,
                isCancelled: isCancelled);
            final rawFrames = await temp.readAsBytes();

            final choices = <(int, int, int, bool)>[];
            final visited = <String>{};
            void offer(int width, int height, int time, bool reused) {
              final key = '$width/$height/$time';
              if (visited.add(key)) choices.add((width, height, time, reused));
            }
            for (final (width, height, time) in runtimeWinningSettings) {
              offer(width, height, time, true);
            }
            for (final profile in remembered.take(12)) {
              offer(profile.width, profile.height, profile.timeBase, true);
            }
            for (final time in _timeBases) {
              for (final (width, height) in _sizes) {
                offer(width, height, time, false);
              }
            }

            var testedThisStart = 0;
            final startBudget = startIndex == 0
                ? firstStartBudget
                : math.max(4,
                    (perSectionBudget - firstStartBudget) ~/
                    math.max(1, starts.length - 1)).toInt();
            for (final (width, height, time, reused) in choices) {
              if (isCancelled()) throw const MpegScanCancelled();
              if (localTrials >= perSectionBudget ||
                  testedThisStart >= startBudget) {
                break;
              }
              if (!reused && syntheticTrials >= _maxHeaderTrials) {
                continue;
              }
              final header = _syntheticVol(width, height, time);
              final probeBytes = Uint8List(header.length + rawFrames.length);
              probeBytes.setRange(0, header.length, header);
              probeBytes.setRange(
                  header.length, probeBytes.length, rawFrames);
              await temp.writeAsBytes(probeBytes);
              final result =
                  await _decodedFrames(temp.path, format, isCancelled);
              localTrials++;
              testedThisStart++;
              testsDone++;
              if (!reused) syntheticTrials++;
              onProbeProgress?.call(testsDone, plannedTests);
              if (result.usable &&
                  (best == null || result.errors < best.errors)) {
                best = result;
                bestHeader = header;
                bestStart = startByte;
                bestSettings = (width, height, time);
                bestFromCache = reused;
                bestDescription = '${width}x$height time-base $time '
                    '(${result.errors} decoder error indicators)'
                    '${reused ? ', reused candidate setting' : ''}';
                if (result.errors == 0) break startLoop;
              }
            }
            if (best != null && best.errors <= 2) break;
          }
          if (bestHeader != null && bestSettings != null) {
            if (bestFromCache) cachedSelections++;
            runtimeWinningSettings.remove(bestSettings);
            runtimeWinningSettings.insert(0, bestSettings);
            winningGuesses.add(bestDescription!);
            candidates.add(Mp4RawRegion(
                bestStart, region.end, format, extension,
                prefixBytes: bestHeader,
                reconstruction: bestDescription,
                guessedWidth: bestSettings.$1,
                guessedHeight: bestSettings.$2,
                guessedTimeBase: bestSettings.$3));
          }
        } else {
          final start = starts.first;
          if (region.end - start < 64 * 1024) continue;
          final end = math.min(region.end, start + 24 * _mib);
          await MpegFullScan.copyByteRange(file, temp, start, end,
              isCancelled: isCancelled);
          final result =
              await _decodedFrames(temp.path, format, isCancelled);
          testsDone++;
          onProbeProgress?.call(testsDone, plannedTests);
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
    onProbeProgress?.call(plannedTests, plannedTests);

    candidates.sort((a, b) {
      final at = a.startByte.compareTo(b.startByte);
      if (at != 0) return at;
      if (a.inputFormat == 'm4v' && b.inputFormat != 'm4v') return -1;
      if (b.inputFormat == 'm4v' && a.inputFormat != 'm4v') return 1;
      return a.endByte.compareTo(b.endByte);
    });
    final nonOverlapping = <Mp4RawRegion>[];
    for (final candidate in candidates) {
      if (nonOverlapping.isNotEmpty &&
          candidate.startByte < nonOverlapping.last.endByte) {
        continue; // Another decoder already verified this byte range.
      }
      nonOverlapping.add(candidate);
    }

    final forensicExplanation = nonOverlapping.isEmpty
        ? await _SmallMp4Forensics.inspect(file, size, isCancelled)
        : '';
    final guessSummary = winningGuesses.isEmpty
        ? ''
        : 'Winning guesses: ${winningGuesses.take(4).join('; ')}. ';
    final sourceExplanation = headerlessFallback
        ? 'No validated top-level mdat box chain survived. Scanned all '
          'source bytes (0–100%) as unindexed raw video in '
          '${windows.length} bounded window(s); decoder verification is '
          'required and no container metadata is assumed. '
        : 'Found ${mdats.length} mdat box(es) '
          '(${mdats.where((range) => range.truncated).length} truncated '
          'at EOF) and inspected all ${windows.length} bounded '
          'media-data window(s). ';
    return UnfinishedMp4Result(nonOverlapping,
        '$sourceExplanation'
        'MPEG-4 Visual markers: $totalVol VOL, $totalVop VOP; '
        'Annex-B candidate SPS: H.264=$totalH264, H.265=$totalH265. '
        'Identified $discovered potential bounded sections; tested '
        '${proposals.length} of them across the full file and found '
        '${nonOverlapping.length} decoder-verified, non-overlapping jobs. '
        '$syntheticTrials new header configurations tested, '
        '$cachedSelections prior or session-success settings reused, '
        '$alternateStarts alternate keyframe starts tried. '
        '$guessSummary'
        '$forensicExplanation'
        '${nonOverlapping.isEmpty ? 'No section passed decoder verification. ' : 'Verified candidates decoded enough frames to attempt extraction. '}'
        'This experimental scanner '
        'recovers video only, with approximate timing and no audio. '
        'Guessed headers are not original metadata: preview reconstructed '
        'results for correct image dimensions and quality. '
        'A missing moov box may also remove essential codec details; '
        'length-prefixed H.264/H.265 samples need a separate conversion '
        'and may not be recoverable without codec configuration.');
  }
}
