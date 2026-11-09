import 'dart:io';

import 'package:droid_vid_player/mpeg_full_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void putMarker(List<int> bytes, int offset, List<int> marker) {
  bytes.setRange(offset, offset + marker.length, marker);
}

void main() {
  test('retains MPEG-1 evidence when no decodable pack window exists', () async {
    final directory = await Directory.systemTemp.createTemp('mpeg_scan_test_');
    try {
      final bytes = List<int>.filled(2 * 1024 * 1024, 0x55);
      putMarker(bytes, 1024, [0, 0, 1, 0xba, 0x44, 0, 0, 0, 0]);
      putMarker(bytes, 2048, [0, 0, 1, 0xe0, 0, 0, 0]);
      // MPEG-1, 720x480, aspect 1, 25 fps (frame-rate code 3).
      putMarker(bytes, 65534, [0, 0, 1, 0xb3, 0x2d, 0x01, 0xe0, 0x13]);
      putMarker(bytes, 75000, [0, 0, 1, 0, 0, 0]);
      putMarker(bytes, 80000, [0, 0, 1, 0, 0, 0]);
      final source = File('${directory.path}/damaged.mpg');
      await source.writeAsBytes(bytes, flush: true);

      final report = await MpegFullScan.scanDetailed(
        source.path, isCancelled: () => false);

      expect(report.verified, isEmpty);
      expect(report.testedWindows, 0); // Only one pack header.
      expect(report.packHeaders, 1);
      expect(report.videoPackets, 1);
      expect(report.sequenceHeaders, 1);
      expect(report.plausibleSequences, 1);
      expect(report.pictureHeaders, 2);
      expect(report.exploratory, hasLength(1));
      expect(report.exploratory.first.exploratory, isTrue);
      expect(report.exploratory.first.inputFormat, 'mpeg');
      expect(report.explanation, contains('NOT verified footage'));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('does not mistake pack headers alone for recoverable video', () async {
    final directory = await Directory.systemTemp.createTemp('mpeg_scan_test_');
    try {
      final bytes = List<int>.filled(2 * 1024 * 1024, 0x55);
      putMarker(bytes, 1024, [0, 0, 1, 0xba, 0x44, 0, 0, 0, 0]);
      final source = File('${directory.path}/audio_only.mpg');
      await source.writeAsBytes(bytes, flush: true);

      final report = await MpegFullScan.scanDetailed(
        source.path, isCancelled: () => false);

      expect(report.exploratory, isEmpty);
      expect(report.verified, isEmpty);
      expect(report.packHeaders, 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
