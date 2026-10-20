import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:saf/saf.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single destination preference used by Guided, Quick, and Deep Recovery.
/// FFmpeg outputs locally first; a verified local copy is exported via
/// Android SAF using streamed I/O. No source video is ever overwritten.
class RecoveryDestination {
  static const _uriKey = 'recovery_destination_uri';
  static const _labelKey = 'recovery_destination_label';
  static final Saf _saf = Saf();
  static final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  static Future<String?> selectedUri() => _prefs.getString(_uriKey);

  static Future<String> selectedLabel() async {
    final uri = await selectedUri();
    if (uri == null || uri.isEmpty) return 'Default: Gallery / Droid Vid Player';
    return await _prefs.getString(_labelKey) ?? 'Selected Android folder';
  }

  static Future<bool> chooseFolder() async {
    if (!Platform.isAndroid) return false;
    final selected = await _saf.pickDirectory(
      writePermission: true, persistablePermission: true);
    if (selected == null) return false;
    await _prefs.setString(_uriKey, selected.uri);
    await _prefs.setString(_labelKey, selected.name);
    return true;
  }

  static Future<void> useGallery() async {
    await _prefs.remove(_uriKey);
    await _prefs.remove(_labelKey);
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
      if (mounted) setState(() => _error = 'Cannot read saved folder: $e');
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
      if (mounted) setState(() => _error = 'Unable to select folder: $e');
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
      if (mounted) setState(() => _error = 'Unable to reset folder: $e');
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
