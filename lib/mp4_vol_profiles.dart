import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A verified MPEG-4 Visual decoder hint. Only dimensions, timebase and a
/// deterministic local file fingerprint are retained. Never stores footage.
class Mp4VolProfile {
  final int width;
  final int height;
  final int timeBase;
  final String sourceKey;
  final int successes;
  final int savedAt;

  const Mp4VolProfile({
    required this.width,
    required this.height,
    required this.timeBase,
    required this.sourceKey,
    required this.successes,
    required this.savedAt,
  });

  String get label => '${width}x$height time-base $timeBase';

  Map<String, Object> toJson() => {
    'width': width,
    'height': height,
    'timeBase': timeBase,
    'sourceKey': sourceKey,
    'successes': successes,
    'savedAt': savedAt,
  };

  static Mp4VolProfile? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final width = value['width'];
    final height = value['height'];
    final timeBase = value['timeBase'];
    final sourceKey = value['sourceKey'];
    final successes = value['successes'];
    final savedAt = value['savedAt'];
    if (width is! int || height is! int || timeBase is! int ||
        sourceKey is! String || successes is! int || savedAt is! int ||
        width < 16 || width > 8191 || height < 16 || height > 8191 ||
        timeBase < 1 || timeBase > 65535) {
      return null;
    }
    return Mp4VolProfile(
      width: width,
      height: height,
      timeBase: timeBase,
      sourceKey: sourceKey,
      successes: successes,
      savedAt: savedAt,
    );
  }
}

/// App-private preferences survive signed APK updates. Profiles are learned
/// only after a produced segment has been independently verified as playable.
class Mp4VolProfiles {
  static const _key = 'droid_mpeg4_verified_vol_profiles_v1';
  static const _maxSaved = 40;

  static Future<String> _fingerprint(String sourcePath) async {
    final source = File(sourcePath);
    final info = await source.stat();
    final descriptor = '${source.absolute.path}|${info.size}|'
        '${info.modified.millisecondsSinceEpoch}';
    var hash = 2166136261; // Deterministic FNV-1a (not a security hash).
    for (final byte in utf8.encode(descriptor)) {
      hash = ((hash ^ byte) * 16777619) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static List<Mp4VolProfile> _read(SharedPreferences preferences) {
    final jsonText = preferences.getString(_key);
    if (jsonText == null) return [];
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! List) return [];
      final profiles = <Mp4VolProfile>[];
      for (final entry in decoded) {
        final profile = Mp4VolProfile.fromJson(entry);
        if (profile != null) profiles.add(profile);
      }
      return profiles;
    } catch (_) {
      // A damaged settings record must not block video recovery.
      return [];
    }
  }

  /// Older builds wrote verified settings into local recovery logs before
  /// there was a profile registry. Read only bounded app-owned reports; no
  /// footage, original source, or report contents leave this device.
  static Future<List<Mp4VolProfile>> _legacySuccessfulReports(
      String sourcePath, String fingerprint) async {
    final folder = Directory(p.join(
        (await getApplicationDocumentsDirectory()).path,
        'DroidVidRecoveries'));
    if (!await folder.exists()) return [];
    final reports = <File>[];
    await for (final item in folder.list(followLinks: false)) {
      if (item is File && item.path.endsWith('.log.txt')) {
        reports.add(item);
      }
    }
    reports.sort((a, b) => b.path.compareTo(a.path));
    final found = <Mp4VolProfile>[];
    final names = <String>{};
    for (final report in reports.take(100)) {
      try {
        if (await report.length() > 512 * 1024) continue;
        final contents = await report.readAsString();
        if (!contents.contains('Source: $sourcePath\n')) continue;
        if (!RegExp(r'Result: [1-9]\d* verified')
            .hasMatch(contents)) {
          continue;
        }
        final match = RegExp(
          r'Reconstructed VOL: (\d+)x(\d+) time-base (\d+)',
        ).firstMatch(contents);
        if (match == null) continue;
        final width = int.tryParse(match.group(1) ?? '');
        final height = int.tryParse(match.group(2) ?? '');
        final time = int.tryParse(match.group(3) ?? '');
        if (width == null || height == null || time == null) continue;
        final key = '$width/$height/$time';
        if (!names.add(key)) continue;
        final profile = Mp4VolProfile.fromJson({
          'width': width, 'height': height, 'timeBase': time,
          'sourceKey': fingerprint, 'successes': 1,
          'savedAt': (await report.lastModified()).millisecondsSinceEpoch,
        });
        if (profile != null) found.add(profile);
        if (found.length >= 5) break;
      } catch (_) {
        // Individual damaged reports should not affect recovery.
      }
    }
    return found;
  }

  /// Same-file verified settings first, then frequently successful settings
  /// from other files. Candidates are still verified before actual recovery.
  static Future<List<Mp4VolProfile>> candidatesFor(
      String sourcePath) async {
    final preferences = await SharedPreferences.getInstance();
    final fingerprint = await _fingerprint(sourcePath);
    final profiles = _read(preferences);
    if (!profiles.any((p) => p.sourceKey == fingerprint)) {
      try {
        profiles.addAll(await _legacySuccessfulReports(
            sourcePath, fingerprint));
      } catch (_) {}
    }
    profiles.sort((a, b) {
      final aMatch = a.sourceKey == fingerprint ? 1 : 0;
      final bMatch = b.sourceKey == fingerprint ? 1 : 0;
      if (aMatch != bMatch) return bMatch.compareTo(aMatch);
      final wins = b.successes.compareTo(a.successes);
      return wins != 0 ? wins : b.savedAt.compareTo(a.savedAt);
    });
    return profiles;
  }

  static Future<void> remember(
      String sourcePath, int width, int height, int timeBase) async {
    if (width < 16 || width > 8191 || height < 16 || height > 8191 ||
        timeBase < 1 || timeBase > 65535) {
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    final fingerprint = await _fingerprint(sourcePath);
    final profiles = _read(preferences);
    var previousSuccesses = 0;
    profiles.removeWhere((profile) {
      final same = profile.width == width && profile.height == height &&
          profile.timeBase == timeBase && profile.sourceKey == fingerprint;
      if (same) previousSuccesses = profile.successes;
      return same;
    });
    profiles.insert(0, Mp4VolProfile(
      width: width,
      height: height,
      timeBase: timeBase,
      sourceKey: fingerprint,
      successes: previousSuccesses + 1,
      savedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    profiles.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    await preferences.setString(_key,
        jsonEncode(profiles.take(_maxSaved).map((p) => p.toJson()).toList()));
  }
}
