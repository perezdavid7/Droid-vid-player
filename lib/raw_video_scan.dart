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
  final int psPackHeaders;
  final int psVideoPackets;
  final int psAudioPackets;
  final int mpegSequenceHeaders;
  final int mpegPictureHeaders;
  final int mpeg4VisualVol;
  final int mpeg4VisualVop;
  final int? mpegSequenceOffset;
  final int validatedMpegSequenceHeaders;
  final String firstBytesHex;

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
    required this.psPackHeaders,
    required this.psVideoPackets,
    required this.psAudioPackets,
    required this.mpegSequenceHeaders,
    required this.mpegPictureHeaders,
    required this.mpeg4VisualVol,
    required this.mpeg4VisualVop,
    required this.mpegSequenceOffset,
    required this.validatedMpegSequenceHeaders,
    required this.firstBytesHex,
  });

  // Evidence for a *bounded decoder probe*, not proof of playable video.
  bool get canProbeMpegVideo =>
      mpegSequenceOffset != null && mpegPictureHeaders >= 8;

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
      'First bytes (hex): $firstBytesHex',
      'Possible MP4 box headers: ftyp=${ftyp ? "yes" : "no"}, '
          'moov=${moov ? "yes" : "no"}, mdat=${mdat ? "yes" : "no"}',
      'MPEG Program Stream signatures: pack=$psPackHeaders, '
          'video PES=$psVideoPackets, audio PES=$psAudioPackets',
      'MPEG-1/2 video start codes: sequence=$mpegSequenceHeaders, '
          'picture=$mpegPictureHeaders',
      'Raw MPEG-4 Visual start codes: VOL=$mpeg4VisualVol, '
          'VOP=$mpeg4VisualVop (signatures do not establish decodability)',
      'Plausible MPEG-2 sequence headers: $validatedMpegSequenceHeaders'
          '${mpegSequenceOffset == null ? '' : ', first at byte $mpegSequenceOffset'}'
          ' (not yet decoded)',
      'Annex-B H.264 signatures: SPS=$h264Sps, PPS=$h264Pps, IDR=$h264Idr',
      'Annex-B H.265 signatures: VPS=$h265Vps, SPS=$h265Sps, '
          'PPS=$h265Pps, keyframes=$h265Irap',
    ];
    if (psPackHeaders > 0 && psVideoPackets > 0) {
      notes.add('MPEG Program Stream pack and video packet markers found. '
          'These are distinct from raw H.264/H.265 Annex-B signatures. '
          'Timestamp defects do not necessarily prevent decoding; '
          'try Quick Repair or Deep Recovery as appropriate.');
    } else if (psPackHeaders > 0) {
      notes.add('MPEG Program Stream pack markers detected. '
          'No video PES markers were identified by this scanner; '
          'a demuxer probe is needed to confirm video tracks.');
    }
    if (rawFormat != null) {
      notes.add('Potential raw ${rawFormat!.toUpperCase()} video starts near '
          'byte ${rawStart!}. An experimental, video-only, lossless stream '
          'copy may be possible. Timing cannot be recovered reliably.');
    } else if (mdat && !moov) {
      notes.add('MP4 media-data marker detected without a moov marker. '
          'Video may be length-prefixed or fragmented; reconstructing it '
          'requires codec/sample information this scanner cannot infer.');
    } else {
      notes.add('No complete H.264/H.265 Annex-B header set identified. '
          'This does not rule out other video codecs or a usable '
          'container; it is not a recovery-feasibility verdict.');
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

/// Stream across the file with fixed-size windows and a 16-byte overlap.
/// Candidate headers are evidence only; not proof of recoverable frames.
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
  var psPackHeaders = 0, psVideoPackets = 0, psAudioPackets = 0;
  var mpegSequenceHeaders = 0, mpegPictureHeaders = 0;
  var mpeg4VisualVol = 0, mpeg4VisualVop = 0;
  int? start264, start265, startMpegSequence;
  var plausibleMpegSequences = 0;
  var consumed = 0;
  var trailing = <int>[];
  final firstBytes = <int>[];

  // Every byte offset is examined exactly once, including offsets crossing
  // chunk boundaries and the tail of short files. The 16-byte lookahead
  // leaves room for 64-bit MP4 box-size candidates and NAL headers.
  void inspect(List<int> data, int base, int lastExclusive) {
    for (var i = 0; i < lastExclusive; i++) {
      if (data[i + 4] == 0x66 || data[i + 4] == 0x6d) {
        // Do not require a zero high-size byte: 256MB/1GB+ mdat boxes
        // commonly have nonzero size bytes.
        if (_box(data, i, 'ftyp')) ftyp = true;
        if (_box(data, i, 'moov')) moov = true;
        if (_box(data, i, 'mdat')) mdat = true;
      }
      if (data[i] != 0 || data[i + 1] != 0) continue;
      final prefix = data[i + 2] == 1
          ? 3 : (data[i + 2] == 0 && data[i + 3] == 1 ? 4 : 0);
      if (prefix == 0) continue;
      final header = data[i + prefix];
      final absolute = base + i;
      // MPEG Program Stream (pack/PES) and MPEG-1/2 elementary stream
      // markers use the same 00 00 01 prefix as raw codec NALs.
      // A PS pack header (0xBA) is not an H.264 SPS; a zero raw
      // H.264 signature count is expected for many playable MPEG PS files.
      if (header == 0xBA) psPackHeaders++;
      if (header >= 0xE0 && header <= 0xEF) psVideoPackets++;
      if (header >= 0xC0 && header <= 0xDF) psAudioPackets++;
      if (header == 0xB3) {
        mpegSequenceHeaders++;
        // MPEG-1/2 sequence header carries width, height, aspect and frame
        // rate immediately after 00 00 01 B3. Screen out impossible sizes
        // and reserved frame-rate codes before reporting a probe position.
        final w = (data[i + prefix + 1] << 4) |
            (data[i + prefix + 2] >> 4);
        final h = ((data[i + prefix + 2] & 0x0f) << 8) |
            data[i + prefix + 3];
        final aspect = data[i + prefix + 4] >> 4;
        final frameRate = data[i + prefix + 4] & 0x0f;
        if (w >= 48 && w <= 4095 && h >= 48 && h <= 4095 &&
            aspect >= 1 && aspect <= 4 &&
            frameRate >= 1 && frameRate <= 8) {
          plausibleMpegSequences++;
          startMpegSequence ??= absolute;
        }
      }
      if (header == 0x00) mpegPictureHeaders++;
      if (header >= 0x20 && header <= 0x2f) mpeg4VisualVol++;
      if (header == 0xb6) mpeg4VisualVop++;
      if ((header & 0x80) == 0) {
        switch (header & 0x1f) {
          case 7:
            sps264++;
            start264 ??= absolute;
            break;
          case 8:
            pps264++;
            break;
          case 5:
            idr264++;
            break;
        }
        final hevcType = (header >> 1) & 0x3f;
        if ((data[i + prefix + 1] & 7) != 0) {
          switch (hevcType) {
            case 32:
              vps265++;
              start265 ??= absolute;
              break;
            case 33:
              sps265++;
              break;
            case 34:
              pps265++;
              break;
            case 19:
            case 20:
            case 21:
              irap265++;
              break;
          }
        }
      }
    }
  }

  await for (final chunk in file.openRead()) {
    if (isCancelled?.call() ?? false) {
      throw const FileSystemException('Scan cancelled');
    }
    if (firstBytes.length < 24) {
      firstBytes.addAll(chunk.take(24 - firstBytes.length));
    }
    final data = <int>[...trailing, ...chunk];
    final base = consumed - trailing.length;
    final scanEnd = data.length > 16 ? data.length - 16 : 0;
    inspect(data, base, scanEnd);
    trailing = data.sublist(scanEnd);
    consumed += chunk.length;
    onProgress?.call(size == 0 ? 1 : consumed / size);
  }
  if (isCancelled?.call() ?? false) {
    throw const FileSystemException('Scan cancelled');
  }
  // Last seven positions cannot contain complete eight-byte MP4 headers.
  // Larger stream chunks have already been fully inspected.
  if (trailing.length >= 8) {
    inspect(trailing, consumed - trailing.length, trailing.length - 7);
  }

  return RawVideoScan(
    fileSize: size, ftyp: ftyp, moov: moov, mdat: mdat,
    h264Sps: sps264, h264Pps: pps264, h264Idr: idr264,
    h265Vps: vps265, h265Sps: sps265, h265Pps: pps265,
    h265Irap: irap265, h264Offset: start264, h265Offset: start265,
    psPackHeaders: psPackHeaders, psVideoPackets: psVideoPackets,
    psAudioPackets: psAudioPackets, mpegSequenceHeaders: mpegSequenceHeaders,
    mpegPictureHeaders: mpegPictureHeaders,
    mpeg4VisualVol: mpeg4VisualVol, mpeg4VisualVop: mpeg4VisualVop,
    mpegSequenceOffset: startMpegSequence,
    validatedMpegSequenceHeaders: plausibleMpegSequences,
    firstBytesHex: firstBytes.map(
      (byte) => byte.toRadixString(16).padLeft(2, '0'),
    ).join(' '),
  );
}
