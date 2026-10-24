import 'dart:io';
import 'dart:math' as math;

/// Finds an MPEG Program Stream pack boundary after a user-chosen physical
/// file position. This uses source BYTES, never damaged source timestamps.
/// No media is copied, moved, removed, or decoded by this scanner.
class MpegRecoveryJump {
  static const int _windowBytes = 16 * 1024 * 1024;
  static const int _chunkBytes = 256 * 1024;

  static Future<MpegJumpResult> locate(
    String path, {
    required int percent,
  }) async {
    if (percent < 10 || percent > 90) {
      throw ArgumentError.value(percent, 'percent', 'Must be 10–90');
    }
    final file = File(path);
    final size = await file.length();
    if (size < 1024 * 1024) {
      throw StateError('The source is too small for byte-jump recovery.');
    }
    final approximate = size ~/ 100 * percent +
        ((size % 100) * percent ~/ 100);
    final stop = math.min(size, approximate + _windowBytes);
    final input = await file.open();
    var cursor = approximate;
    var trailing = <int>[];
    try {
      await input.setPosition(approximate);
      while (cursor < stop) {
        final bytes = await input.read(math.min(_chunkBytes, stop - cursor));
        if (bytes.isEmpty) break;
        final window = <int>[...trailing, ...bytes];
        final base = cursor - trailing.length;
        for (var i = 0; i + 8 < window.length; i++) {
          if (window[i] != 0 || window[i + 1] != 0 ||
              window[i + 2] != 1 || window[i + 3] != 0xba) {
            continue;
          }
          // MPEG-2 PS pack headers begin with '01..0100'; MPEG-1
          // pack headers begin with '0010'. Filter random false matches.
          final header = window[i + 4];
          final mpeg2 = header & 0xc4 == 0x44;
          final mpeg1 = header & 0xf0 == 0x20;
          if (mpeg2 || mpeg1) {
            final boundary = base + i;
            if (boundary >= approximate) {
              return MpegJumpResult(
                sourceBytes: size,
                percent: percent,
                requestedByte: approximate,
                alignedByte: boundary,
              );
            }
          }
        }
        cursor += bytes.length;
        trailing = window.length < 8
            ? window : window.sublist(window.length - 8);
      }
    } finally {
      await input.close();
    }
    throw StateError('No MPEG program-stream pack boundary was found '
        'within 16 MB after the selected $percent% position. '
        'Try a different percentage; no recovery files were created.');
  }
}

class MpegJumpResult {
  final int sourceBytes;
  final int percent;
  final int requestedByte;
  final int alignedByte;
  const MpegJumpResult({
    required this.sourceBytes,
    required this.percent,
    required this.requestedByte,
    required this.alignedByte,
  });
}
