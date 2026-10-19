import 'dart:io';
import 'dart:math' as math;

/// Conservative format identification using fixed-size samples and, for
/// ISO-BMFF files, validated top-level box boundaries. Never repairs or edits
/// the source file. High entropy does NOT establish encryption or compression.
class FileIdentification {
  final String format;
  final String category;
  final String evidence;
  final String pattern;
  final double entropy;
  final int sampledBytes;
  final String mp4Boxes;
  final bool hasMoov;
  final bool hasMdat;
  final bool mp4Truncated;

  const FileIdentification({
    required this.format,
    required this.category,
    required this.evidence,
    required this.pattern,
    required this.entropy,
    required this.sampledBytes,
    required this.mp4Boxes,
    required this.hasMoov,
    required this.hasMdat,
    required this.mp4Truncated,
  });

  bool get isNonVideo => category == 'nonvideo';
  bool get isMp4Family => category == 'mp4';
}

bool _match(List<int> bytes, int at, List<int> magic) {
  if (at < 0 || at + magic.length > bytes.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[at + i] != magic[i]) return false;
  }
  return true;
}

bool _ascii(List<int> bytes, int at, String value) =>
    _match(bytes, at, value.codeUnits);

int _be32(List<int> bytes, int i) =>
    (bytes[i] << 24) | (bytes[i + 1] << 16) |
    (bytes[i + 2] << 8) | bytes[i + 3];

/// Finds recognized signatures at the *start* of a file. Extensions, incidental
/// byte patterns, and byte entropy are not accepted as format evidence.
(String, String, String) _identify(List<int> b) {
  if (b.isEmpty) return ('Empty file', 'nonvideo', 'Zero-byte file');
  if (b.length >= 12 && _ascii(b, 4, 'ftyp')) {
    final size = _be32(b, 0);
    if (size >= 16 && (size == 1 || size <= 1024 * 1024)) {
      final brand = String.fromCharCodes(b.sublist(8, 12));
      if (_ascii(b, 8, 'heic') || _ascii(b, 8, 'heix') ||
          _ascii(b, 8, 'mif1') || _ascii(b, 8, 'avif')) {
        return ('HEIF/AVIF image container ($brand)', 'nonvideo',
            'ISO media-file header and image brand');
      }
      return ('MP4 / ISO media container ($brand)', 'mp4',
          'ISO base-media ftyp header');
    }
  }
  if (_ascii(b, 0, 'RIFF') && _ascii(b, 8, 'AVI ')) {
    return ('AVI video', 'video', 'RIFF AVI header');
  }
  if (_ascii(b, 0, 'RIFF') && _ascii(b, 8, 'WAVE')) {
    return ('WAV audio', 'nonvideo', 'RIFF WAVE header');
  }
  if (_match(b, 0, const [0x1a, 0x45, 0xdf, 0xa3])) {
    return ('Matroska / WebM container', 'video', 'EBML header');
  }
  if (_ascii(b, 0, 'FLV')) {
    return ('Flash video (FLV)', 'video', 'FLV header');
  }
  if (_match(b, 0, const [0x30, 0x26, 0xb2, 0x75, 0x8e, 0x66,
      0xcf, 0x11, 0xa6, 0xd9, 0x00, 0xaa, 0x00, 0x62, 0xce, 0x6c])) {
    return ('ASF / WMV / WMA container', 'video', 'ASF GUID');
  }
  if (_match(b, 0, const [0, 0, 1, 0xba])) {
    return ('MPEG program stream', 'video', 'MPEG pack header');
  }
  if (b.length >= 377 && b[0] == 0x47 &&
      b[188] == 0x47 && b[376] == 0x47) {
    return ('MPEG transport stream', 'video', '188-byte sync pattern');
  }
  if (_ascii(b, 0, 'OggS')) {
    return ('Ogg container (codec unknown)', 'media', 'OggS header');
  }
  if (_ascii(b, 0, 'ID3') ||
      (b.length >= 2 && b[0] == 0xff && (b[1] & 0xe0) == 0xe0)) {
    return ('Likely MP3 audio', 'nonvideo', 'Audio frame or ID3 header');
  }
  if (_match(b, 0, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return ('PNG image', 'nonvideo', 'PNG header');
  }
  if (_match(b, 0, const [0xff, 0xd8, 0xff])) {
    return ('JPEG image', 'nonvideo', 'JPEG header');
  }
  if (_ascii(b, 0, 'GIF87a') || _ascii(b, 0, 'GIF89a')) {
    return ('GIF image / animation', 'nonvideo', 'GIF header');
  }
  if (_ascii(b, 0, '%PDF-')) {
    return ('PDF document', 'nonvideo', 'PDF header');
  }
  if (_match(b, 0, const [0x50, 0x4b, 0x03, 0x04]) ||
      _match(b, 0, const [0x50, 0x4b, 0x05, 0x06])) {
    return ('ZIP archive', 'nonvideo', 'ZIP header');
  }
  if (_match(b, 0, const [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])) {
    return ('7-Zip archive', 'nonvideo', '7z header');
  }
  if (_match(b, 0, const [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07])) {
    return ('RAR archive', 'nonvideo', 'RAR header');
  }
  if (_match(b, 0, const [0x1f, 0x8b, 0x08])) {
    return ('Gzip data', 'nonvideo', 'Gzip header');
  }
  return ('Unknown data / unrecognized header', 'unknown',
      'No known file signature at byte 0');
}

class _Mp4Inspection {
  final String description;
  final bool moov, mdat, truncated;
  const _Mp4Inspection(this.description, this.moov, this.mdat,
      this.truncated);
}

Future<_Mp4Inspection> _inspectMp4(RandomAccessFile handle, int total,
    {bool Function()? isCancelled}) async {
  var offset = 0;
  var moov = false, mdat = false, truncated = false;
  final boxes = <String>[];
  // Jump box-to-box; do not buffer gigabyte-sized mdat payloads.
  for (var count = 0; count < 256 && offset + 8 <= total; count++) {
    if (isCancelled?.call() ?? false) {
      throw const FileSystemException('Scan cancelled');
    }
    await handle.setPosition(offset);
    final header = await handle.read(16);
    if (header.length < 8) break;
    final type = String.fromCharCodes(header.sublist(4, 8));
    if (!RegExp(r'^[a-zA-Z0-9 ]{4}$').hasMatch(type)) {
      truncated = true;
      break;
    }
    var length = _be32(header, 0);
    var headerLength = 8;
    if (length == 1) {
      if (header.length < 16 || header[8] >= 128) {
        truncated = true;
        break;
      }
      length = 0;
      for (var i = 8; i < 16; i++) {
        length = (length << 8) | header[i];
      }
      headerLength = 16;
    } else if (length == 0) {
      length = total - offset;
    }
    if (length < headerLength || length > total - offset) {
      truncated = true;
      break;
    }
    boxes.add(type);
    if (type == 'moov') moov = true;
    if (type == 'mdat') mdat = true;
    offset += length;
    if (offset == total) break;
  }
  if (offset < total && !truncated) {
    // If box list exceeds our safety limit, this is not a verified full walk.
    boxes.add('…');
  }
  return _Mp4Inspection(
      boxes.isEmpty ? 'No valid top-level boxes' : boxes.join(' → '),
      moov, mdat, truncated);
}

/// Identifies a file with at most ~192 KiB of sample data in memory.
/// The full, independently cancellable raw-marker scan remains in
/// scanRawVideo; this inspection is supplementary and does not modify files.
Future<FileIdentification> identifyFile(
  String path, {
  bool Function()? isCancelled,
}) async {
  final handle = await File(path).open();
  try {
    final total = await handle.length();
    final startBytes = await handle.read(math.min(total, 384));
    final (format, category, evidence) = _identify(startBytes);
    var boxes = 'Not an identified MP4-family header';
    var hasMoov = false, hasMdat = false, truncated = false;
    if (category == 'mp4') {
      final result = await _inspectMp4(handle, total,
          isCancelled: isCancelled);
      boxes = result.description;
      hasMoov = result.moov;
      hasMdat = result.mdat;
      truncated = result.truncated;
    }

    const window = 64 * 1024;
    final offsets = total <= 3 * window
        ? <int>[0]
        : <int>[0, (total - window) ~/ 2, total - window];
    final histogram = List<int>.filled(256, 0);
    var sampled = 0;
    var zeroCount = 0;
    for (final offset in offsets) {
      if (isCancelled?.call() ?? false) {
        throw const FileSystemException('Scan cancelled');
      }
      await handle.setPosition(offset);
      final requested = total <= 3 * window
          ? total : window;
      // Small files are sampled once in full; large files use three windows.
      final data = await handle.read(requested);
      for (final byte in data) {
        histogram[byte]++;
        if (byte == 0) zeroCount++;
      }
      sampled += data.length;
    }
    var entropy = 0.0;
    var dominant = 0;
    for (final n in histogram) {
      if (n > dominant) dominant = n;
      if (n == 0 || sampled == 0) continue;
      final frequency = n / sampled;
      entropy -= frequency * (math.log(frequency) / math.ln2);
    }
    final pattern = sampled == 0
        ? 'Empty data'
        : zeroCount / sampled > 0.95
            ? 'Mostly zero-filled data'
            : dominant / sampled > 0.85
                ? 'Highly repetitive bytes'
                : entropy >= 7.75
                    ? 'High byte diversity (could be compressed, encrypted, '
                        'or unrelated data)'
                    : 'Mixed byte patterns (no format inference)';
    return FileIdentification(
      format: format, category: category, evidence: evidence,
      pattern: pattern, entropy: entropy, sampledBytes: sampled,
      mp4Boxes: boxes, hasMoov: hasMoov, hasMdat: hasMdat,
      mp4Truncated: truncated,
    );
  } finally {
    await handle.close();
  }
}
