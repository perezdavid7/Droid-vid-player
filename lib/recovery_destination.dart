import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:saf/saf.dart';
import 'package:path_provider/path_provider.dart';

/// A single destination preference used by Guided, Quick, and Deep Recovery.
/// FFmpeg outputs locally first; a verified local copy is exported via
/// Android SAF using streamed I/O. No source video is ever overwritten.
class RecoveryDestination {
  static const _uriKey = 'recovery_destination_uri';
  static const _labelKey = 'recovery_destination_label';
  static final Saf _saf = Saf();
  static const _storageName = 'recovery_destination.json';

  // Avoid the Android SharedPreferencesAsync Pigeon runtime ABI mismatch.
  // A tiny app-private JSON file is sufficient for these two values.
  static Future<File> _settingsFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(p.join(directory.path, _storageName));
  }

  static Future<Map<String, String>> _loadSettings() async {
    final file = await _settingsFile();
    if (!await file.exists()) return <String, String>{};
    final data = jsonDecode(await file.readAsString());
    if (data is! Map) throw const FormatException('Invalid folder settings');
    return <String, String>{
      for (final entry in data.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  static Future<void> _storeSettings(Map<String, String> settings) async {
    final file = await _settingsFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(settings), flush: true);
    await temporary.rename(file.path);
  }

  static Future<String?> selectedUri() async {
    return (await _loadSettings())[_uriKey];
  }

  static Future<String> selectedLabel() async {
    final settings = await _loadSettings();
    final uri = settings[_uriKey];
    if (uri == null || uri.isEmpty) {
      return 'Default: Gallery / Droid Vid Player';
    }
    return settings[_labelKey] ?? 'Selected Android folder';
  }

  static Future<bool> chooseFolder() async {
    if (!Platform.isAndroid) return false;
    final selected = await _saf.pickDirectory(
      writePermission: true, persistablePermission: true);
    if (selected == null) return false;
    await _storeSettings(<String, String>{
      _uriKey: selected.uri,
      _labelKey: selected.name,
    });
    return true;
  }

  static Future<void> useGallery() async {
    await _storeSettings(<String, String>{});
  }

  static Future<String> exportRecoveredVideo(String localPath) async {
    final uri = await selectedUri();
    if (uri == null || uri.isEmpty) {
      if (!Platform.isAndroid) {
        throw UnsupportedError('Gallery export requires Android.');
      }
      await Gal.putVideo(localPath, album: 'Droid Vid Player');
      return 'Gallery / Droid Vid Player';
    }
    await exportToChosenFolder(localPath);
    return await selectedLabel();
  }

  /// Copies a reconstructed video to the user's SAF folder and reads it back
  /// byte-for-byte before permitting its app-private output to be removed.
  /// This does not delete anything. When verification cannot finish, callers
  /// MUST retain their private local output for a safe retry.
  static Future<String> exportVerifiedReconstruction(String localPath) async {
    final localFile = File(localPath);
    final expectedBytes = await localFile.length();
    if (expectedBytes < 4096) {
      throw StateError('Reconstruction output is too small to export safely.');
    }
    final exportedUri = await exportToChosenFolder(localPath);
    if (exportedUri == null || exportedUri.isEmpty) {
      throw StateError('Choose an output folder before exporting.');
    }

    final remote = await _saf.stat(exportedUri);
    if (remote == null || remote.isDir || remote.length != expectedBytes) {
      throw StateError('The exported file could not be verified at the '
          'destination. The local reconstructed video has been retained.');
    }

    // Read the destination in bounded chunks; never create another copy or
    // load a multi-gigabyte recovery into memory. Comparing the whole file
    // catches silent truncation and byte differences before local deletion.
    final local = await localFile.open(mode: FileMode.read);
    var checked = 0;
    try {
      final stream = await _saf.readFileStream(
        exportedUri, bufferSize: 1024 * 1024);
      await for (final remoteBytes in stream) {
        if (remoteBytes.isEmpty) continue;
        final localBytes = await local.read(remoteBytes.length);
        if (localBytes.length != remoteBytes.length ||
            checked + remoteBytes.length > expectedBytes) {
          throw StateError('Export verification failed: file length changed. '
              'The local reconstructed video has been retained.');
        }
        for (var i = 0; i < remoteBytes.length; i++) {
          if (remoteBytes[i] != localBytes[i]) {
            throw StateError('Export verification found different video '
                'bytes. The local reconstructed video has been retained.');
          }
        }
        checked += remoteBytes.length;
      }
      if (checked != expectedBytes) {
        throw StateError('Export verification was incomplete '
            '($checked of $expectedBytes bytes). '
            'The local reconstructed video has been retained.');
      }
    } finally {
      await local.close();
    }
    return exportedUri;
  }

  static Future<String?> exportToChosenFolder(String localPath) async {
    final uri = await selectedUri();
    if (uri == null || uri.isEmpty) return null;
    if (!Platform.isAndroid) {
      throw UnsupportedError('Android folder export is not available here.');
    }
    final filename = p.basename(localPath);
    final extension = p.extension(filename).toLowerCase();
    final mime = extension == '.mkv' ? 'video/x-matroska'
        : extension == '.mpg' || extension == '.mpeg'
            ? 'video/mpeg' : 'video/mp4';
    // SAF performs a streamed transfer without loading the entire video
    // into memory. Keep the local working copy for player playback and
    // for retrying export on permission/storage errors.
    final saved = await _saf.pasteLocalFile(
      localPath, uri, filename, mime, overwrite: false);
    return saved.uri;
  }
}

/// Shared UI; changing the folder here changes it for every recovery mode.
class RecoveryDestinationPicker extends StatefulWidget {
  final bool disabled;
  final VoidCallback? onChanged;
  const RecoveryDestinationPicker({
    super.key, this.disabled = false, this.onChanged,
  });

  @override
  State<RecoveryDestinationPicker> createState() =>
      _RecoveryDestinationPickerState();
}

class _RecoveryDestinationPickerState extends State<RecoveryDestinationPicker> {
  String _label = 'Loading destination…';
  String? _error;
  bool _busy = false;
  bool _custom = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final uri = await RecoveryDestination.selectedUri();
      final label = await RecoveryDestination.selectedLabel();
      if (mounted) {
        setState(() {
          _custom = uri != null && uri.isNotEmpty;
          _label = label;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not load saved recovery folder.');
      }
      debugPrint('Folder preference read failed: $e');
    }
  }

  Future<void> _pick() async {
    setState(() { _busy = true; _error = null; });
    try {
      final changed = await RecoveryDestination.chooseFolder();
      if (changed) {
        await _reload();
        widget.onChanged?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Unable to save the selected folder.');
      }
      debugPrint('Folder selection failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    setState(() { _busy = true; _error = null; });
    try {
      await RecoveryDestination.useGallery();
      await _reload();
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Unable to reset the recovery folder.');
      }
      debugPrint('Folder reset failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _busy || widget.disabled;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Recovery output destination',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(_label),
            const SizedBox(height: 4),
            const Text('Used by Guided, Quick and Deep Recovery. '
                'Files are processed locally, then exported to this '
                'folder. Large videos need temporary device storage.',
                style: TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              OutlinedButton.icon(
                onPressed: blocked || !Platform.isAndroid ? null : _pick,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose folder'),
              ),
              if (_custom)
                TextButton(
                  onPressed: blocked ? null : _reset,
                  child: const Text('Use Gallery'),
                ),
            ]),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(_error!, style: const TextStyle(
                  color: Colors.orangeAccent, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
