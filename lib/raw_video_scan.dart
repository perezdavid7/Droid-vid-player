import 'dart:io';

/// Conservative byte-level triage for damaged files from an unknown source.
///
/// This is not an MP4 index reconstructor. It looks for MP4 box markers and
/// complete Annex-B H.264/H.265 parameter-set / keyframe evidence. A missing
/// moov box alone does not establish that any video is recoverable.
class RawVideoScan {
  final int fileSize;
  final bool ftyp;
  final bool moov;
  final bool mdat;
  final int h264Sps;
  final int h264Pps;
  final int h264Idr;
  final int h265Vps;
  final int h265Sps;
  final int h265Pps;
  final int h265Irap;
  final int? h264Offset;
  final int? h265Offset;

  const RawVideoScan({
    required this.fileSize,
    required this.ftyp,
    required this.moov,
    required this.mdat,
    required this.h264Sps,
    required this.h264Pps,
    required this.h264Idr,
    required this.h265Vps,
    required this.h265Sps,
    required this.h265Pps,
    required this.h265Irap,
    required this.h264Offset,
    required this.h265Offset,
  });

  bool get canCopyH264 =>
      h264Offset != null && h264Sps > 0 && h264Pps > 0 && h264Idr > 0;
  bool get canCopyH265 =>
      h265Offset != null && h265Vps > 0 && h265Sps > 0 &&
      h265Pps > 0 && h265Irap > 0;
  String? get rawFormat =>
      canCopyH264 ? 'h264' : canCopyH265 ? 'hevc' : null;
  int? get rawStart =>
      canCopyH264 ? h264Offset : canCopyH265 ? h265Offset : null;

  String get diagnostic {
    final notes = <String>[
      'File size: ${(fileSize / (1024 * 1024)).toStringAsFixed(2)} MiB',
      'MP4 box markers: ftyp=${ftyp ? "yes" : "no"}, '
          'moov=${moov ? "yes" : "no"}, mdat=${mdat ? "yes" : "no"}',
      'Annex-B H.264 signatures: SPS=$h264Sps, PPS=$h264Pps, IDR=$h264Idr',
      'Annex-B H.265 signatures: VPS=$h265Vps, SPS=$h265Sps, '
          'PPS=$h265Pps, keyframes=$h265Irap',
    ];
    if (rawFormat != null) {
      notes.add('Potential raw ${rawFormat!.toUpperCase()} video starts near '
          'byte ${rawStart!}. An experimental, video-only, lossless stream '
          'copy may be possible. Timing cannot be recovered reliably.');
    } else if (mdat && !moov) {
      notes.add('MP4 media-data marker detected without a moov marker. '
          'Video may be length-prefixed or fragmented; reconstructing it '
          'requires codec/sample information this scanner cannot infer.');
    } else {
      notes.add('No sufficiently identified raw Annex-B video stream found. '
          'A different codec, missing key headers, or overwritten data '
          'may be responsible. No recovery can be assumed.');
    }
    return notes.join('\n');
  }
}

bool _box(List<int> data, int i, String name) {
  if (data[i + 4] != name.codeUnitAt(0) ||
      data[i + 5] != name.codeUnitAt(1) ||
      data[i + 6] != name.codeUnitAt(2) ||
      data[i + 7] != name.codeUnitAt(3)) {
    return false;
  }
  final length = data[i] * 0x1000000 +
      data[i + 1] * 0x10000 + data[i + 2] * 0x100 + data[i + 3];
  return length == 0 || length == 1 || length >= 8;
}

Future<RawVideoScan> scanRawVideo(
  String path, {
  void Function(double)? onProgress,
  bool Function()? isCancelled,
}) async {
  final file = File(path);
  final size = await file.length();
  var ftyp = false, moov = false, mdat = false;
  var sps264 = 0, pps264 = 0, idr264 = 0;
  var vps265 = 0, sps265 = 0, pps265 = 0, irap265 = 0;
  int? start264, start265;
  var consumed = 0;
  var trailing = <int>[];

  // Bounded memory: process the entire file in chunks, retaining 16 bytes
  // to cover byte patterns crossing chunk boundaries.
  await for (final chunk in file.openRead()) {
    if (isCancelled?.call() ?? false) {
      throw const FileSystemException('Scan cancelled');
    }
    final data = <int>[...trailing, ...chunk];
    final base = consumed - trailing.length;
    final scanLimit = data.length - 16;
    for (var i = 0; i <= scanLimit; i++) {
      if (data[i] != 0) continue;
      if (_box(data, i, 'ftyp')) ftyp = true;
      if (_box(data, i, 'moov')) moov = true;
      if (_box(data, i, 'mdat')) mdat = true;
      if (data[i + 1] != 0) continue;
      final prefix = data[i + 2] == 1
          ? 3 : (data[i + 2] == 0 && data[i + 3] == 1 ? 4 : 0);
      if (prefix == 0) continue;
      final header = data[i + prefix];
      final absolute = base + i;
      // Forbid malformed/reserved NAL types and require parameter sets.
      if ((header & 0x80) == 0) {
        switch (header & 0x1f) {
          case 7:
            sps264++;
            start264 ??= absolute;
          case 8:
            pps264++;
          case 5:
            idr264++;
        }
        final hevcType = (header >> 1) & 0x3f;
        if ((data[i + prefix + 1] & 7) != 0) {
          switch (hevcType) {
            case 32:
              vps265++;
              start265 ??= absolute;
            case 33:
              sps265++;
            case 34:
              pps265++;
            case 19:
            case 20:
            case 21:
              irap265++;
          }
        }
      }
      i += prefix - 1; // Do not count both 3-byte and 4-byte prefixes.
    }
    trailing = data.length <= 16 ? data : data.sublist(data.length - 16);
    consumed += chunk.length;
    onProgress?.call(size == 0 ? 1 : consumed / size);
  }

  return RawVideoScan(
    fileSize: size, ftyp: ftyp, moov: moov, mdat: mdat,
    h264Sps: sps264, h264Pps: pps264, h264Idr: idr264,
    h265Vps: vps265, h265Sps: sps265, h265Pps: pps265,
    h265Irap: irap265, h264Offset: start264, h265Offset: start265,
  );
}

/// Creates a separate temporary stream; never modifies the recovered source.
/// Copying raw bytes is not itself a playable reconstruction.
Future<void> copyRawTail(
  String source,
  String destination,
  int startOffset, {
  bool Function()? isCancelled,
}) async {
  final input = await File(source).open();
  final output = File(destination).openWrite();
  try {
    await input.setPosition(startOffset);
    while (true) {
      if (isCancelled?.call() ?? false) {
        throw const FileSystemException('Copy cancelled');
      }
      final bytes = await input.read(256 * 1024);
      if (bytes.isEmpty) break;
      output.add(bytes);
    }
    await output.flush();
    await output.close();
  } catch (_) {
    await output.close();
    final scratch = File(destination);
    if (await scratch.exists()) await scratch.delete();
    rethrow;
  } finally {
    await input.close();
  }
}
