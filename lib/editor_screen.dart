// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

class EditorClip {
  EditorClip(this.id, this.path, this.name, this.length, this.start, this.end,
      {this.turns = 0, this.zoom = 1, this.x = 0.5, this.y = 0.5,
      this.isImage = false, this.imageWidth = 0, this.imageHeight = 0,
      this.speed = 1, this.brightness = 0, this.contrast = 1,
      this.saturation = 1, this.clarity = 0, this.overlayPath,
      this.overlayWidth = 0, this.overlayHeight = 0,
      this.overlaySize = 0.35, this.overlayX = 0.5, this.overlayY = 0.5,
      this.overlayOpacity = 1, this.reverse = false});
  final int id;
  final String path;
  final String name;
  final int length;
  int start;
  int end;
  int turns;
  double zoom;
  double x;
  double y;
  final bool isImage;
  final int imageWidth;
  final int imageHeight;
  double speed;
  double brightness;
  double contrast;
  double saturation;
  double clarity;
  String? overlayPath;
  int overlayWidth;
  int overlayHeight;
  double overlaySize;
  double overlayX;
  double overlayY;
  double overlayOpacity;
  bool reverse;

  EditorClip duplicate(int newId) =>
      EditorClip(newId, path, name, length, start, end,
          turns: turns, zoom: zoom, x: x, y: y,
          isImage: isImage, imageWidth: imageWidth, imageHeight: imageHeight,
          speed: speed, brightness: brightness, contrast: contrast,
          saturation: saturation, clarity: clarity,
          overlayPath: overlayPath, overlayWidth: overlayWidth,
          overlayHeight: overlayHeight, overlaySize: overlaySize,
          overlayX: overlayX, overlayY: overlayY,
          overlayOpacity: overlayOpacity, reverse: reverse);

  Map<String, Object?> toJson() => {
    'id': id, 'path': path, 'name': name, 'length': length,
    'start': start, 'end': end, 'turns': turns, 'zoom': zoom,
    'x': x, 'y': y, 'isImage': isImage,
    'imageWidth': imageWidth, 'imageHeight': imageHeight,
    'speed': speed, 'brightness': brightness, 'contrast': contrast,
    'saturation': saturation, 'clarity': clarity,
    'overlayPath': overlayPath, 'overlayWidth': overlayWidth,
    'overlayHeight': overlayHeight, 'overlaySize': overlaySize,
    'overlayX': overlayX, 'overlayY': overlayY,
    'overlayOpacity': overlayOpacity, 'reverse': reverse,
  };

  factory EditorClip.fromJson(Map<String, dynamic> data) => EditorClip(
    (data['id'] as num).toInt(),
    data['path'] as String,
    data['name'] as String,
    (data['length'] as num).toInt(),
    (data['start'] as num).toInt(),
    (data['end'] as num).toInt(),
    turns: (data['turns'] as num?)?.toInt() ?? 0,
    zoom: (data['zoom'] as num?)?.toDouble() ?? 1,
    x: (data['x'] as num?)?.toDouble() ?? 0.5,
    y: (data['y'] as num?)?.toDouble() ?? 0.5,
    isImage: data['isImage'] == true,
    imageWidth: (data['imageWidth'] as num?)?.toInt() ?? 0,
    imageHeight: (data['imageHeight'] as num?)?.toInt() ?? 0,
    speed: (data['speed'] as num?)?.toDouble() ?? 1,
    brightness: (data['brightness'] as num?)?.toDouble() ?? 0,
    contrast: (data['contrast'] as num?)?.toDouble() ?? 1,
    saturation: (data['saturation'] as num?)?.toDouble() ?? 1,
    clarity: (data['clarity'] as num?)?.toDouble() ?? 0,
    overlayPath: data['overlayPath'] as String?,
    overlayWidth: (data['overlayWidth'] as num?)?.toInt() ?? 0,
    overlayHeight: (data['overlayHeight'] as num?)?.toInt() ?? 0,
    overlaySize: (data['overlaySize'] as num?)?.toDouble() ?? 0.35,
    overlayX: (data['overlayX'] as num?)?.toDouble() ?? 0.5,
    overlayY: (data['overlayY'] as num?)?.toDouble() ?? 0.5,
    overlayOpacity: (data['overlayOpacity'] as num?)?.toDouble() ?? 1,
    reverse: data['reverse'] == true,
  );
}

class EditorProject {
  EditorProject(this.id, this.name, this.updatedAt);
  final String id;
  String name;
  int updatedAt;

  Map<String, Object> toJson() => {
    'id': id, 'name': name, 'updatedAt': updatedAt,
  };

  factory EditorProject.fromJson(Map<String, dynamic> data) =>
      EditorProject(
        data['id'] as String,
        data['name'] as String,
        (data['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});
  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _clips = <EditorClip>[];
  final _projects = <EditorProject>[];
  String? _projectId;
  Future<void> _saveTail = Future<void>.value();
  String _transition = 'None';
  double _transitionSeconds = 0.5;
  VideoPlayerController? _player;
  Timer? _photoTimer;
  int? _activeId;
  int _at = 0;
  int _nextId = 1;
  int _generation = 0;
  int? _sessionId;
  bool _busy = false;
  bool _cancelled = false;
  bool _playingSequence = false;
  bool _transitioning = false;
  int? _scrubMs;
  String _ratio = '16:9';
  String _message = 'Import photos or videos. Originals stay untouched.';
  String? _error;
  String _section = 'Edit';
  double _gestureStartZoom = 1;
  double _overlayGestureStartSize = 0.35;

  EditorClip? get _active {
    for (final c in _clips) {
      if (c.id == _activeId) return c;
    }
    return null;
  }

  String get _projectName {
    for (final project in _projects) {
      if (project.id == _projectId) return project.name;
    }
    return 'Droid Vid Editor';
  }

  int _clipDuration(EditorClip clip) => clip.isImage
      ? clip.end - clip.start
      : ((clip.end - clip.start) / clip.speed).round();

  int get _timelineLength =>
      _clips.fold<int>(0, (sum, c) => sum + _clipDuration(c));

  int _clipOffset(EditorClip clip) {
    var elapsed = 0;
    for (final item in _clips) {
      if (item.id == clip.id) return elapsed;
      elapsed += _clipDuration(item);
    }
    return 0;
  }

  int get _timelineAt {
    final clip = _active;
    if (clip == null) return 0;
    return _clipOffset(clip) +
        ((_at - clip.start) / clip.speed)
            .round().clamp(0, _clipDuration(clip));
  }

  String _time(int ms) {
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'DroidVidEditor'));
    await root.create(recursive: true);
    return root;
  }

  Future<File> _projectIndex() async =>
      File(p.join((await _root()).path, 'project_index.json'));

  Future<File> _projectFile(String id) async {
    final folder = Directory(p.join((await _root()).path, 'projects'));
    await folder.create(recursive: true);
    return File(p.join(folder.path, id + '.json'));
  }

  Future<void> _writeProjectIndex() async {
    final file = await _projectIndex();
    final temp = File(file.path + '.partial');
    await temp.writeAsString(jsonEncode({
      'version': 1,
      'activeId': _projectId,
      'projects': _projects.map((project) => project.toJson()).toList(),
    }), flush: true);
    await temp.rename(file.path);
  }

  Future<void> _save() {
    final id = _projectId;
    if (id == null) return Future<void>.value();
    final snapshot = jsonEncode({
      'version': 2,
      'ratio': _ratio,
      'transition': _transition,
      'transitionSeconds': _transitionSeconds,
      'clips': _clips.map((clip) => clip.toJson()).toList(),
    });
    for (final project in _projects) {
      if (project.id == id) {
        project.updatedAt = DateTime.now().millisecondsSinceEpoch;
      }
    }
    _saveTail = _saveTail.catchError((Object _) {}).then((_) async {
      final file = await _projectFile(id);
      final temp = File(file.path + '.partial');
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(file.path);
      await _writeProjectIndex();
    });
    return _saveTail.catchError((Object error) {
      if (mounted) setState(() => _error = 'Save failed: $error');
    });
  }

  Future<void> _clearPreviewAndClips() async {
    _generation++;
    _pausePreview();
    _photoTimer?.cancel();
    _photoTimer = null;
    final old = _player;
    _player = null;
    old?.removeListener(_watch);
    if (old != null) await old.dispose();
    if (!mounted) return;
    setState(() {
      _clips.clear();
      _activeId = null;
      _nextId = 1;
      _at = 0;
      _scrubMs = null;
      _ratio = '16:9';
      _transition = 'None';
      _transitionSeconds = 0.5;
      _section = 'Edit';
      _error = null;
    });
  }

  Future<void> _loadProject(String id) async {
    await _clearPreviewAndClips();
    if (!mounted) return;
    final file = await _projectFile(id);
    final restored = <EditorClip>[];
    String ratio = '16:9';
    String transition = 'None';
    double seconds = 0.5;
    if (await file.exists()) {
      final data = jsonDecode(await file.readAsString());
      if (data is Map && data['clips'] is List) {
        for (final raw in data['clips'] as List) {
          try {
            final clip = EditorClip.fromJson(
                Map<String, dynamic>.from(raw as Map));
            if (clip.start >= 0 && clip.end > clip.start &&
                clip.end <= clip.length && clip.speed > 0 &&
                await File(clip.path).exists()) {
              restored.add(clip);
            }
          } catch (_) {}
        }
        if (const ['16:9', '9:16', '1:1'].contains(data['ratio'])) {
          ratio = data['ratio'] as String;
        }
        if (const ['None', 'Fade', 'Wipe'].contains(data['transition'])) {
          transition = data['transition'] as String;
        }
        seconds = ((data['transitionSeconds'] as num?)?.toDouble() ?? 0.5)
            .clamp(0.25, 1.0).toDouble();
      }
    }
    if (!mounted) return;
    setState(() {
      _projectId = id;
      _clips.addAll(restored);
      _ratio = ratio;
      _transition = transition;
      _transitionSeconds = seconds;
      for (final clip in _clips) {
        if (clip.id >= _nextId) _nextId = clip.id + 1;
      }
      _message = 'Opened ' + _projectName + ' • ' +
          restored.length.toString() + ' clips.';
    });
    await _writeProjectIndex();
    if (_clips.isNotEmpty) await _open(_clips.first);
  }

  Future<void> _load() async {
    try {
      final index = await _projectIndex();
      if (await index.exists()) {
        final raw = jsonDecode(await index.readAsString());
        if (raw is Map && raw['projects'] is List) {
          for (final entry in raw['projects'] as List) {
            try {
              final project = EditorProject.fromJson(
                  Map<String, dynamic>.from(entry as Map));
              if (project.id.startsWith('project_')) {
                _projects.add(project);
              }
            } catch (_) {}
          }
          if (_projects.isNotEmpty) {
            final active = raw['activeId'] as String?;
            final id = _projects.any((p) => p.id == active)
                ? active! : _projects.first.id;
            await _loadProject(id);
            return;
          }
        }
      }
      final id = 'project_' + DateTime.now().microsecondsSinceEpoch.toString();
      _projects.add(EditorProject(id, 'My first edit',
          DateTime.now().millisecondsSinceEpoch));
      _projectId = id;
      final legacy = File(p.join((await _root()).path,
          'current_project.json'));
      if (await legacy.exists()) {
        final migrated = await _projectFile(id);
        await legacy.copy(migrated.path);
      }
      await _loadProject(id);
    } catch (error) {
      if (mounted) setState(() => _error = 'Load failed: $error');
    }
  }

  Future<String?> _askProjectName(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Project name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    return name == null || name.isEmpty ? null : name;
  }

  Future<void> _newProject() async {
    if (_busy) return;
    final name = await _askProjectName('New project', 'Untitled edit');
    if (name == null || !mounted) return;
    await _save();
    final id = 'project_' + DateTime.now().microsecondsSinceEpoch.toString();
    _projects.add(EditorProject(id, name,
        DateTime.now().millisecondsSinceEpoch));
    await _clearPreviewAndClips();
    if (!mounted) return;
    setState(() {
      _projectId = id;
      _message = 'New project: ' + name;
    });
    await _save();
  }

  Future<void> _switchProject(String id) async {
    if (_busy || id == _projectId) return;
    await _save();
    await _loadProject(id);
  }

  Future<void> _renameProject() async {
    if (_busy || _projectId == null) return;
    final name = await _askProjectName('Rename project', _projectName);
    if (name == null || !mounted) return;
    for (final project in _projects) {
      if (project.id == _projectId) project.name = name;
    }
    setState(() {});
    await _writeProjectIndex();
  }

  Future<void> _showProjects() async {
    if (_busy) return;
    await _save();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: (MediaQuery.sizeOf(ctx).height * 0.65)
              .clamp(300.0, 620.0).toDouble(),
          child: Column(children: [
            ListTile(
              title: const Text('Saved projects',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Open a different edit or start a new one'),
              trailing: IconButton(
                tooltip: 'New project',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () {
                  Navigator.pop(ctx);
                  unawaited(_newProject());
                },
              ),
            ),
            Expanded(child: ListView(
              children: [
                for (final project in _projects.reversed)
                  ListTile(
                    leading: Icon(project.id == _projectId
                        ? Icons.movie_outlined : Icons.folder_outlined),
                    title: Text(project.name),
                    subtitle: Text(project.id == _projectId
                        ? 'Currently open' : 'Tap to open'),
                    trailing: project.id == _projectId
                        ? const Icon(Icons.check_circle)
                        : const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(ctx);
                      unawaited(_switchProject(project.id));
                    },
                  ),
              ],
            )),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    unawaited(_renameProject());
                  },
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Rename current'),
                )),
                const SizedBox(width: 8),
                Expanded(child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    unawaited(_newProject());
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('New project'),
                )),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _photoTimer?.cancel();
    _player?.removeListener(_watch);
    final old = _player;
    if (old != null) unawaited(old.dispose());
    super.dispose();
  }

  Future<void> _open(EditorClip clip,
      {int? position, bool autoplay = false}) async {
    if (_busy) return;
    final generation = ++_generation;
    _playingSequence = autoplay;
    _photoTimer?.cancel();
    _photoTimer = null;
    final old = _player;
    _player = null;
    old?.removeListener(_watch);
    if (old != null) await old.dispose();
    if (!mounted || generation != _generation) return;
    final target = (position ?? clip.start).clamp(clip.start, clip.end);
    setState(() {
      _activeId = clip.id;
      _at = target;
      _error = null;
    });
    if (clip.isImage) {
      if (autoplay) _startPhotoPlayback();
      return;
    }
    final next = VideoPlayerController.file(File(clip.path));
    try {
      await next.initialize().timeout(const Duration(seconds: 25));
      if (!mounted || generation != _generation) {
        await next.dispose();
        return;
      }
      await next.seekTo(Duration(milliseconds: target));
      await next.setPlaybackSpeed(clip.speed);
      next.addListener(_watch);
      setState(() => _player = next);
      if (autoplay) {
        await next.play();
        if (mounted && generation == _generation) setState(() {});
      }
    } catch (error) {
      _playingSequence = false;
      await next.dispose();
      if (mounted && generation == _generation) {
        setState(() => _error = 'Preview failed: $error');
      }
    }
  }

  void _startPhotoPlayback() {
    final clip = _active;
    if (clip == null || !clip.isImage || !_playingSequence) return;
    _photoTimer?.cancel();
    final began = DateTime.now();
    final startingAt = _at;
    _photoTimer = Timer.periodic(const Duration(milliseconds: 70), (timer) {
      if (!mounted || !_playingSequence || _activeId != clip.id) {
        timer.cancel();
        if (_photoTimer == timer) _photoTimer = null;
        return;
      }
      final at = startingAt + DateTime.now().difference(began).inMilliseconds;
      if (at >= clip.end) {
        timer.cancel();
        if (_photoTimer == timer) _photoTimer = null;
        if (!_transitioning) {
          _transitioning = true;
          unawaited(_advanceSequence());
        }
      } else {
        setState(() => _at = at);
      }
    });
    if (mounted) setState(() {});
  }

  void _watch() {
    final clip = _active;
    final player = _player;
    if (!mounted || clip == null || player == null) return;
    final current = player.value.position.inMilliseconds;
    if (_playingSequence && !_transitioning &&
        (current >= clip.end - 45 || player.value.isCompleted)) {
      _transitioning = true;
      unawaited(_advanceSequence());
      return;
    }
    if (current >= clip.end && player.value.isPlaying) {
      unawaited(player.pause());
    }
    if ((current - _at).abs() >= 80) {
      setState(() => _at = current.clamp(clip.start, clip.end));
    }
  }

  Future<void> _advanceSequence() async {
    try {
      final index = _clips.indexWhere((c) => c.id == _activeId);
      if (!_playingSequence || index < 0) return;
      if (index == _clips.length - 1) {
        _playingSequence = false;
        _photoTimer?.cancel();
        _photoTimer = null;
        await _player?.pause();
        if (mounted) setState(() => _at = _clips[index].end);
        return;
      }
      await _open(_clips[index + 1], autoplay: true);
    } finally {
      _transitioning = false;
    }
  }

  Future<void> _seek(int target) async {
    final clip = _active;
    final player = _player;
    if (clip == null || player == null) return;
    final actual = target.clamp(clip.start, clip.end);
    setState(() => _at = actual);
    await player.seekTo(Duration(milliseconds: actual));
  }

  bool get _isPreviewPlaying =>
      _active?.isImage == true
          ? _photoTimer != null
          : (_player?.value.isPlaying ?? false);

  void _pausePreview() {
    _playingSequence = false;
    _photoTimer?.cancel();
    _photoTimer = null;
    final player = _player;
    if (player != null) unawaited(player.pause());
  }

  Future<void> _seekTimeline(int target) async {
    if (_busy || _clips.isEmpty) return;
    final wasPlaying = _playingSequence && _isPreviewPlaying;
    var remaining = target.clamp(0, _timelineLength);
    for (var i = 0; i < _clips.length; i++) {
      final clip = _clips[i];
      final duration = _clipDuration(clip);
      if (remaining < duration || i == _clips.length - 1) {
        final sourcePosition = clip.start +
            (remaining.clamp(0, duration) * clip.speed).round();
        if (clip.id == _activeId &&
            (clip.isImage || _player != null)) {
          if (clip.isImage) {
            setState(() => _at = sourcePosition);
            if (wasPlaying) _startPhotoPlayback();
          } else {
            await _seek(sourcePosition);
          }
        } else {
          await _open(clip, position: sourcePosition, autoplay: wasPlaying);
        }
        return;
      }
      remaining -= duration;
    }
  }

  Future<void> _togglePlayback() async {
    final clip = _active;
    if (clip == null || _busy) return;
    if (_isPreviewPlaying) {
      _pausePreview();
    } else if (_timelineAt >= _timelineLength - 60 && _clips.isNotEmpty) {
      await _open(_clips.first, autoplay: true);
    } else {
      _playingSequence = true;
      if (clip.isImage) {
        _startPhotoPlayback();
      } else {
        await _player?.play();
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _import() async {
    if (_busy) return;
    final chosen = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'mp4', 'm4v', 'mov', 'mkv', 'avi', 'webm',
        'mpeg', 'mpg', 'mts', 'm2ts', 'ts', 'vob', 'wmv',
        'jpg', 'jpeg', 'png', 'webp',
      ],
    );
    if (chosen.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = 'Copying selected media into private editor storage…';
    });
    final additions = <EditorClip>[];
    final skipped = <String>[];
    try {
      final root = await _root();
      final dir = Directory(p.join(root.path, 'media'));
      await dir.create(recursive: true);
      for (final item in chosen) {
        final source = item.path;
        if (source == null || !await File(source).exists()) {
          skipped.add(item.name);
          continue;
        }
        final unique = DateTime.now().microsecondsSinceEpoch.toString() +
            '_' + additions.length.toString() + p.extension(item.name);
        final copy = File(p.join(dir.path, unique));
        VideoPlayerController? probe;
        try {
          await File(source).copy(copy.path);
          final ext = p.extension(item.name).toLowerCase();
          if (const ['.jpg', '.jpeg', '.png', '.webp'].contains(ext)) {
            final bytes = await copy.readAsBytes();
            final codec = await ui.instantiateImageCodec(
                bytes, targetWidth: 512);
            try {
              final frame = await codec.getNextFrame();
              final width = frame.image.width;
              final height = frame.image.height;
              frame.image.dispose();
              if (width <= 0 || height <= 0) {
                throw StateError('Invalid photo dimensions');
              }
              additions.add(EditorClip(
                _nextId++, copy.path, item.name, 3600000, 0, 5000,
                isImage: true, imageWidth: width, imageHeight: height,
              ));
            } finally {
              codec.dispose();
            }
          } else {
            probe = VideoPlayerController.file(copy);
            await probe.initialize().timeout(const Duration(seconds: 25));
            final duration = probe.value.duration.inMilliseconds;
            if (duration < 500) throw StateError('No usable frames');
            additions.add(EditorClip(
                _nextId++, copy.path, item.name, duration, 0, duration));
          }
        } catch (_) {
          skipped.add(item.name);
          if (await copy.exists()) await copy.delete();
        } finally {
          if (probe != null) await probe.dispose();
        }
      }
      if (!mounted) return;
      setState(() {
        _clips.addAll(additions);
        _message = 'Imported ' + additions.length.toString() + ' clips.' +
            (skipped.isEmpty ? '' : ' Skipped: ' + skipped.join(', '));
      });
      await _save();
    } catch (error) {
      if (mounted) setState(() => _error = 'Import failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _active == null && _clips.isNotEmpty) {
      await _open(_clips.first);
    }
  }

  Future<void> _addPhotoOverlay() async {
    final clip = _active;
    if (clip == null || _busy) return;
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
    );
    if (picked.isEmpty || !mounted) return;
    final source = picked.first.path;
    if (source == null || !await File(source).exists()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dir = Directory(p.join((await _root()).path, 'media'));
      await dir.create(recursive: true);
      final name = 'overlay_' +
          DateTime.now().microsecondsSinceEpoch.toString() +
          p.extension(picked.first.name);
      final copy = await File(source).copy(p.join(dir.path, name));
      final codec = await ui.instantiateImageCodec(
          await copy.readAsBytes(), targetWidth: 512);
      try {
        final frame = await codec.getNextFrame();
        final width = frame.image.width;
        final height = frame.image.height;
        frame.image.dispose();
        if (width <= 0 || height <= 0) {
          throw StateError('Invalid overlay picture');
        }
        if (!mounted) return;
        setState(() {
          clip.overlayPath = copy.path;
          clip.overlayWidth = width;
          clip.overlayHeight = height;
          clip.overlaySize = 0.35;
          clip.overlayX = 0.5;
          clip.overlayY = 0.5;
          clip.overlayOpacity = 1;
          _section = 'Layers';
          _message = 'Photo layer added to this clip.';
        });
        await _save();
      } finally {
        codec.dispose();
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Layer import failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _removeOverlay() {
    _change((clip) {
      clip.overlayPath = null;
      clip.overlayWidth = 0;
      clip.overlayHeight = 0;
    });
  }

  void _setSpeedAndSave(double speed) {
    _setSpeed(speed);
    unawaited(_save());
  }

  void _toggleReverse() {
    final clip = _active;
    if (clip == null || clip.isImage || _busy) return;
    if (!clip.reverse && clip.end - clip.start > 10000) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Reverse currently supports clips up to 10 seconds. '
            'Trim or split this clip first.'),
      ));
      return;
    }
    _change((c) => c.reverse = !c.reverse);
  }

  void _setSpeed(double speed) {
    final clip = _active;
    if (clip == null || clip.isImage || _busy) return;
    setState(() => clip.speed = speed);
    final player = _player;
    if (player != null) unawaited(player.setPlaybackSpeed(speed));
  }

  void _change(void Function(EditorClip) update) {
    final clip = _active;
    if (clip == null || _busy) return;
    setState(() => update(clip));
    unawaited(_save());
  }

  void _setIn() {
    final clip = _active;
    if (clip == null || _at >= clip.end - 300) return;
    _change((c) => c.start = _at);
  }

  void _setOut() {
    final clip = _active;
    if (clip == null || _at <= clip.start + 300) { return; }
    _change((c) => c.end = _at);
  }

  void _split() {
    final clip = _active;
    if (clip == null || _busy ||
        _at <= clip.start + 300 || _at >= clip.end - 300) {
      return;
    }
    setState(() {
      final second = clip.duplicate(_nextId++);
      second.start = _at;
      clip.end = _at;
      _clips.insert(_clips.indexOf(clip) + 1, second);
      _message = 'Split complete. Both pieces are retained.';
    });
    unawaited(_save());
  }

  void _duplicate() {
    final clip = _active;
    if (clip == null || _busy) return;
    setState(() {
      _clips.insert(_clips.indexOf(clip) + 1, clip.duplicate(_nextId++));
      _message = 'Clip duplicated next to the original.';
    });
    unawaited(_save());
  }

  void _remove() {
    final clip = _active;
    if (clip == null || _busy) return;
    final index = _clips.indexOf(clip);
    setState(() {
      _clips.remove(clip);
      _activeId = null;
    });
    unawaited(_save());
    if (_clips.isNotEmpty) {
      unawaited(_open(_clips[index.clamp(0, _clips.length - 1)]));
    } else {
      final old = _player;
      _player = null;
      old?.removeListener(_watch);
      if (old != null) unawaited(old.dispose());
    }
  }

  Future<bool> _run(List<String> arguments) async {
    final complete = Completer<bool>();
    int? id;
    try {
      final session = await FFmpegKit.executeWithArgumentsAsync(
        arguments,
        (finished) async {
          final code = await finished.getReturnCode();
          if (!complete.isCompleted) {
            complete.complete(ReturnCode.isSuccess(code));
          }
        },
      );
      id = session.getSessionId();
      _sessionId = id;
      return await complete.future.timeout(const Duration(minutes: 30));
    } on TimeoutException {
      if (id != null) await FFmpegKit.cancel(id);
      return false;
    } catch (_) {
      return false;
    } finally {
      _sessionId = null;
    }
  }

  Future<bool> _hasAudio(String path) async {
    try {
      final result = await FFprobeKit.getMediaInformation(path);
      final streams = result.getMediaInformation()?.getStreams();
      return streams?.any((s) => s.getType() == 'audio') ?? false;
    } catch (_) {
      return false;
    }
  }

  String _audioTempo(double speed) {
    var remaining = speed;
    final stages = <String>[];
    while (remaining < 0.5) {
      stages.add('atempo=0.5');
      remaining /= 0.5;
    }
    while (remaining > 2) {
      stages.add('atempo=2.0');
      remaining /= 2;
    }
    stages.add('atempo=' + remaining.toStringAsFixed(3));
    return stages.join(',');
  }

  void _cancelExport() {
    _cancelled = true;
    final id = _sessionId;
    if (id != null) unawaited(FFmpegKit.cancel(id));
    if (mounted) setState(() => _message = 'Cancelling export…');
  }

  Future<bool> _joinWithTransitions(List<String> parts,
      List<double> durations, String output, double seconds) async {
    final kind = _transition == 'Wipe' ? 'wipeleft' : 'fade';
    final graph = <String>[];
    for (var i = 0; i < parts.length; i++) {
      graph.add('[' + i.toString() +
          ':v]fps=30,format=yuv420p,settb=AVTB,' +
          'setpts=PTS-STARTPTS[v' + i.toString() + ']');
      graph.add('[' + i.toString() +
          ':a]aresample=44100,asetpts=PTS-STARTPTS[a' +
          i.toString() + ']');
    }
    var sum = durations.first;
    for (var i = 1; i < parts.length; i++) {
      final previousVideo = i == 1
          ? 'v0' : 'vxf' + (i - 1).toString();
      final previousAudio = i == 1
          ? 'a0' : 'axf' + (i - 1).toString();
      final at = (sum - i * seconds).clamp(0.0, double.infinity);
      graph.add('[' + previousVideo + '][v' + i.toString() +
          ']xfade=transition=' + kind +
          ':duration=' + seconds.toStringAsFixed(3) +
          ':offset=' + at.toStringAsFixed(3) +
          '[vxf' + i.toString() + ']');
      graph.add('[' + previousAudio + '][a' + i.toString() +
          ']acrossfade=d=' + seconds.toStringAsFixed(3) +
          '[axf' + i.toString() + ']');
      sum += durations[i];
    }
    final finalIndex = (parts.length - 1).toString();
    final expected = durations.fold<double>(0, (a, b) => a + b) -
        seconds * (parts.length - 1);
    return _run([
      '-hide_banner', '-nostdin', '-loglevel', 'error',
      for (final path in parts) ...['-i', path],
      '-filter_complex', graph.join(';'),
      '-map', '[vxf' + finalIndex + ']',
      '-map', '[axf' + finalIndex + ']',
      '-r', '30', '-c:v', 'mpeg4', '-q:v', '2',
      '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-b:a', '160k', '-ar', '44100', '-ac', '2',
      '-t', expected.toStringAsFixed(3),
      '-movflags', '+faststart', '-y', output,
    ]);
  }

  Future<void> _export() async {
    if (_busy || _clips.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export edited video?'),
        content: const Text('This first editor build exports 720p, 30 fps '
            'MP4. Your project, imported source copies, and originals '
            'remain unchanged. Rendering may take several minutes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Export'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
    });
    try {
      _pausePreview();
      final root = await _root();
      final work = Directory(p.join(root.path, 'export_work'));
      final exports = Directory(p.join(root.path, 'exports'));
      await work.create(recursive: true);
      await exports.create(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch.toString();
      final size = switch (_ratio) {
        '9:16' => [720, 1280],
        '1:1' => [720, 720],
        _ => [1280, 720],
      };
      final parts = <String>[];
      final partDurations = <double>[];
      for (var i = 0; i < _clips.length; i++) {
        if (_cancelled) throw StateError('Export cancelled');
        final clip = _clips[i];
        if (mounted) {
          setState(() => _message =
              'Rendering clip ' + (i + 1).toString() +
              ' of ' + _clips.length.toString() + '…');
        }
        final filters = <String>[
          if (!clip.isImage)
            'setpts=(PTS-STARTPTS)/' + clip.speed.toStringAsFixed(3),
          ...List.filled(clip.turns % 4, 'transpose=1'),
          'crop=iw/' + clip.zoom.toStringAsFixed(3) +
              ':ih/' + clip.zoom.toStringAsFixed(3) +
              ':(iw-ow)*' + clip.x.toStringAsFixed(3) +
              ':(ih-oh)*' + clip.y.toStringAsFixed(3),
          'scale=' + size[0].toString() + ':' + size[1].toString() +
              ':force_original_aspect_ratio=increase',
          'crop=' + size[0].toString() + ':' + size[1].toString(),
          if (clip.reverse && !clip.isImage)
            'reverse,setpts=PTS-STARTPTS',
          if (clip.brightness != 0 || clip.contrast != 1 ||
              clip.saturation != 1)
            'eq=brightness=' + clip.brightness.toStringAsFixed(3) +
                ':contrast=' + clip.contrast.toStringAsFixed(3) +
                ':saturation=' + clip.saturation.toStringAsFixed(3),
          if (clip.clarity > 0.001)
            'unsharp=5:5:' + clip.clarity.toStringAsFixed(3),
          'setsar=1',
        ].join(',');
        final output = p.join(work.path,
            stamp + '_clip_' + i.toString() + '.mp4');
        final audio = clip.isImage ? false : await _hasAudio(clip.path);
        final hasOverlay = clip.overlayPath != null &&
            await File(clip.overlayPath!).exists();
        final overlayIndex = audio ? 1 : 2;
        final layerWidth = (size[0] * clip.overlaySize).round().clamp(2, size[0]);
        final layerFilter = '[' + overlayIndex.toString() + ':v]' +
            'scale=' + layerWidth.toString() + ':-2,format=rgba,' +
            'colorchannelmixer=aa=' +
            clip.overlayOpacity.toStringAsFixed(3) + '[layer]';
        final composite = '[0:v]' + filters + '[base];' +
            layerFilter + ';[base][layer]overlay=x=W*' +
            clip.overlayX.toStringAsFixed(3) + '-w/2:y=H*' +
            clip.overlayY.toStringAsFixed(3) + '-h/2' +
            ':format=auto[vout]';
        final arguments = <String>[
          '-hide_banner', '-nostdin', '-loglevel', 'error',
          if (clip.isImage) ...[
            '-loop', '1', '-framerate', '30',
          ] else ...[
            '-ss', (clip.start / 1000).toStringAsFixed(3),
          ],
          '-t', ((clip.end - clip.start) / 1000).toStringAsFixed(3),
          '-i', clip.path,
          if (!audio) ...[
            '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo',
          ],
          if (hasOverlay) ...[
            '-loop', '1', '-framerate', '30',
            '-i', clip.overlayPath!,
          ],
          if (hasOverlay) ...[
            '-filter_complex', composite,
            '-map', '[vout]',
          ] else ...[
            '-map', '0:v:0',
            '-vf', filters,
          ],
          '-map', audio ? '0:a:0' : '1:a:0',
          if (audio && !clip.isImage &&
              (clip.speed != 1 || clip.reverse))
            ...['-af', [
              if (clip.reverse) 'areverse',
              if (clip.speed != 1) _audioTempo(clip.speed),
            ].join(',')],
          '-r', '30', '-fps_mode', 'cfr',
          '-c:v', 'mpeg4', '-q:v', '2', '-threads:v', '2',
          '-pix_fmt', 'yuv420p',
          '-c:a', 'aac', '-b:a', '160k', '-ar', '44100', '-ac', '2',
          '-t', (_clipDuration(clip) / 1000).toStringAsFixed(3),
          '-y', output,
        ];
        if (!await _run(arguments) || !await File(output).exists()) {
          throw StateError('Could not encode clip ' + (i + 1).toString());
        }
        parts.add(output);
        final encoded = await FFprobeKit.getMediaInformation(output);
        final actualDuration = double.tryParse(
            encoded.getMediaInformation()?.getDuration() ?? '');
        partDurations.add(actualDuration != null && actualDuration > 0
            ? actualDuration : _clipDuration(clip) / 1000);
      }
      if (_cancelled) throw StateError('Export cancelled');
      final partial = File(p.join(exports.path,
          'DroidVidEditor_' + stamp + '.partial.mp4'));
      var transitionNote = '';
      if (parts.length == 1) {
        await File(parts.first).copy(partial.path);
      } else {
        var joined = false;
        if (_transition != 'None') {
          final shortest = partDurations.reduce(
              (a, b) => a < b ? a : b);
          final seconds = _transitionSeconds < shortest / 3
              ? _transitionSeconds : shortest / 3;
          if (seconds >= 0.20) {
            if (mounted) {
              setState(() =>
                  _message = 'Rendering ' + _transition + ' transitions…');
            }
            joined = await _joinWithTransitions(
                parts, partDurations, partial.path, seconds);
            if (!joined) {
              transitionNote = ' Transitions failed; used straight cuts.';
            }
          } else {
            transitionNote = ' Clips too short for transitions; used cuts.';
          }
        }
        if (!joined) {
          final list = File(p.join(work.path, stamp + '.concat.txt'));
          await list.writeAsString(
            parts.map((path) => "file '" + path + "'").join('\n') + '\n',
            flush: true,
          );
          if (mounted) setState(() => _message = 'Joining clips…');
          if (!await _run([
            '-hide_banner', '-nostdin', '-loglevel', 'error',
            '-f', 'concat', '-safe', '0', '-i', list.path,
            '-c', 'copy', '-movflags', '+faststart', '-y', partial.path,
          ])) {
            throw StateError('Could not join edited clips');
          }
        }
      }
      if (_cancelled) throw StateError('Export cancelled');
      if (!await partial.exists() || await partial.length() < 1024) {
        throw StateError('Output file is missing or empty');
      }
      final info = await FFprobeKit.getMediaInformation(partial.path);
      final duration = double.tryParse(
          info.getMediaInformation()?.getDuration() ?? '') ?? 0;
      if (duration <= 0) {
        throw StateError('Output could not be verified');
      }
      final finished = await partial.rename(p.join(exports.path,
          'DroidVidEditor_' + stamp + '.mp4'));
      var message = 'Verified export saved in private editor storage.';
      try {
        await Gal.putVideo(finished.path, album: 'Droid Vid Editor');
        message = 'Export verified and copied to Gallery.';
      } catch (error) {
        message += ' Gallery copy failed: $error';
      }
      if (mounted) setState(() => _message = message + transitionNote);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }


  void _onVideoGestureStart(EditorClip clip) {
    _gestureStartZoom = clip.zoom;
    if (_isPreviewPlaying) _pausePreview();
  }

  void _onVideoGestureUpdate(
      EditorClip clip, ScaleUpdateDetails details, Size frame) {
    if (_busy) return;
    final video = _player;
    if (!clip.isImage &&
        (video == null || !video.value.isInitialized)) {
      return;
    }
    final aspect = clip.isImage
        ? clip.imageWidth / clip.imageHeight
        : video!.value.aspectRatio;
    final rotatedAspect = clip.turns.isOdd ? 1 / aspect : aspect;
    final drawnWidth = frame.width > frame.height * rotatedAspect
        ? frame.width
        : frame.height * rotatedAspect;
    final drawnHeight = frame.height > frame.width / rotatedAspect
        ? frame.height
        : frame.width / rotatedAspect;
    final nextZoom =
        (_gestureStartZoom * details.scale).clamp(1.0, 3.0).toDouble();
    var nextX = clip.x;
    var nextY = clip.y;
    if (nextZoom > 1.01) {
      nextX = (nextX -
          details.focalPointDelta.dx / (drawnWidth * (nextZoom - 1)))
          .clamp(0.0, 1.0).toDouble();
      nextY = (nextY -
          details.focalPointDelta.dy / (drawnHeight * (nextZoom - 1)))
          .clamp(0.0, 1.0).toDouble();
    } else {
      nextX = 0.5;
      nextY = 0.5;
    }
    setState(() {
      clip.zoom = nextZoom;
      clip.x = nextX;
      clip.y = nextY;
    });
  }

  void _resetFrame() {
    _change((c) {
      c.zoom = 1;
      c.x = 0.5;
      c.y = 0.5;
    });
  }

  List<double> _colorMatrix(EditorClip clip) {
    final saturation = clip.saturation;
    final contrast = clip.contrast;
    final red = 0.2126 * (1 - saturation);
    final green = 0.7152 * (1 - saturation);
    final blue = 0.0722 * (1 - saturation);
    final offset = (1 - contrast) * 128 + clip.brightness * 255;
    return [
      contrast * (red + saturation), contrast * green,
      contrast * blue, 0, offset,
      contrast * red, contrast * (green + saturation),
      contrast * blue, 0, offset,
      contrast * red, contrast * green,
      contrast * (blue + saturation), 0, offset,
      0, 0, 0, 1, 0,
    ];
  }

  Widget _videoFrame(EditorClip? clip, VideoPlayerController? player) {
    final ratio = switch (_ratio) {
      '9:16' => 9 / 16,
      '1:1' => 1.0,
      _ => 16 / 9,
    };
    final viewportHeight =
        (MediaQuery.sizeOf(context).height * 0.38).clamp(220.0, 355.0).toDouble();
    return SizedBox(
      height: viewportHeight,
      child: Center(
        child: AspectRatio(
          aspectRatio: ratio,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final frame = Size(
                  constraints.maxWidth, constraints.maxHeight);
              if (clip == null || (!clip.isImage &&
                  (player == null || !player.value.isInitialized))) {
                return Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: const Text('Import photos or videos to preview'),
                );
              }
              final sourceSize = clip.isImage
                  ? Size(clip.imageWidth.toDouble(),
                      clip.imageHeight.toDouble())
                  : player!.value.size;
              final turned = clip.turns.isOdd;
              final displayWidth =
                  turned ? sourceSize.height : sourceSize.width;
              final displayHeight =
                  turned ? sourceSize.width : sourceSize.height;
              final drawnWidth =
                  frame.width > frame.height * displayWidth / displayHeight
                      ? frame.width
                      : frame.height * displayWidth / displayHeight;
              final drawnHeight =
                  frame.height > frame.width * displayHeight / displayWidth
                      ? frame.height
                      : frame.width * displayHeight / displayWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _busy ? null
                    : (_) => _onVideoGestureStart(clip),
                onScaleUpdate: _busy ? null
                    : (details) => _onVideoGestureUpdate(clip, details, frame),
                onScaleEnd: _busy ? null
                    : (_) => unawaited(_save()),
                child: ClipRect(
                  child: Stack(children: [
                    Positioned.fill(
                      child: Transform.translate(
                        offset: Offset(
                          (0.5 - clip.x) * drawnWidth * (clip.zoom - 1),
                          (0.5 - clip.y) * drawnHeight * (clip.zoom - 1),
                        ),
                        child: Transform.scale(
                          scale: clip.zoom,
                          child: FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: displayWidth,
                              height: displayHeight,
                              child: ColorFiltered(
                                colorFilter: ColorFilter.matrix(
                                    _colorMatrix(clip)),
                                child: RotatedBox(
                                  quarterTurns: clip.turns,
                                  child: clip.isImage
                                    ? Image.file(File(clip.path),
                                        fit: BoxFit.fill,
                                        cacheWidth: 1080,
                                        errorBuilder: (context, error, stack) =>
                                            const Center(child:
                                                Text('Photo unavailable')))
                                    : VideoPlayer(player!),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (clip.overlayPath != null &&
                        clip.overlayWidth > 0 && clip.overlayHeight > 0)
                      Positioned(
                        left: clip.overlayX * frame.width -
                            frame.width * clip.overlaySize / 2,
                        top: clip.overlayY * frame.height -
                            frame.width * clip.overlaySize *
                                clip.overlayHeight / clip.overlayWidth / 2,
                        child: GestureDetector(
                          onScaleStart: _busy ? null : (_) {
                            _overlayGestureStartSize = clip.overlaySize;
                            _pausePreview();
                          },
                          onScaleUpdate: _busy ? null : (details) {
                            setState(() {
                              clip.overlaySize =
                                  (_overlayGestureStartSize * details.scale)
                                      .clamp(0.1, 0.9).toDouble();
                              clip.overlayX = (clip.overlayX +
                                  details.focalPointDelta.dx / frame.width)
                                      .clamp(0.0, 1.0).toDouble();
                              clip.overlayY = (clip.overlayY +
                                  details.focalPointDelta.dy / frame.height)
                                      .clamp(0.0, 1.0).toDouble();
                            });
                          },
                          onScaleEnd: _busy ? null :
                              (_) => unawaited(_save()),
                          child: Opacity(
                            opacity: clip.overlayOpacity,
                            child: Image.file(File(clip.overlayPath!),
                              width: frame.width * clip.overlaySize,
                              height: frame.width * clip.overlaySize *
                                  clip.overlayHeight / clip.overlayWidth,
                              fit: BoxFit.fill,
                              cacheWidth: 800,
                            ),
                          ),
                        ),
                      ),
                    if (!_busy)
                      const Positioned(
                        left: 8,
                        bottom: 8,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0xA0000000),
                              borderRadius: BorderRadius.all(
                                  Radius.circular(6)),
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(6),
                              child: Text('Pinch to zoom • Drag to move',
                                  style: TextStyle(fontSize: 11)),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _previewControls() {
    final duration = _timelineLength;
    final timelineAt = (_scrubMs ?? _timelineAt).clamp(0, duration);
    return SizedBox(
      height: 54,
      child: Row(children: [
        IconButton(
          tooltip: _isPreviewPlaying
              ? 'Pause the project' : 'Play all clips in order',
          onPressed: _busy || _active == null ||
                  (_active?.isImage != true && _player == null)
              ? null : () => unawaited(_togglePlayback()),
          icon: Icon(_isPreviewPlaying
              ? Icons.pause : Icons.play_arrow),
        ),
        Text(_time(timelineAt),
            style: const TextStyle(fontSize: 12)),
        Expanded(child: Slider(
          min: 0,
          max: duration > 0 ? duration.toDouble() : 1.0,
          value: timelineAt.toDouble(),
          onChangeStart: _busy || duration == 0 ? null : (v) {
            _pausePreview();
            setState(() => _scrubMs = v.round());
          },
          onChanged: _busy || duration == 0 ? null
              : (v) => setState(() => _scrubMs = v.round()),
          onChangeEnd: _busy || duration == 0 ? null : (v) async {
            await _seekTimeline(v.round());
            if (mounted) setState(() => _scrubMs = null);
          },
        )),
        Text(_time(duration),
            style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 8),
      ]),
    );
  }

  Widget _clipStrip() {
    if (_clips.isEmpty) {
      return const SizedBox(
        height: 77,
        child: Center(child: Text('Imported clips appear here on the timeline')),
      );
    }
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 88,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            const Text('Timeline',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Tap a clip to jump • Play runs them all',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.white70)),
            ),
            Text(_clips.length.toString() + ' clips',
                style: const TextStyle(fontSize: 11)),
          ]),
        ),
        const SizedBox(height: 5),
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: _clips.length,
            itemBuilder: (context, index) {
              final item = _clips[index];
              final duration = _clipDuration(item);
              final width =
                  (duration / 1000 * 12).clamp(100.0, 250.0).toDouble();
              final selected = item.id == _activeId;
              final progress = selected && duration > 0
                  ? ((_at - item.start) / duration).clamp(0.0, 1.0).toDouble()
                  : 0.0;
              return GestureDetector(
                onTapUp: _busy ? null : (details) {
                  final fraction =
                      (details.localPosition.dx / width).clamp(0.0, 1.0);
                  final at = _clipOffset(item) + (fraction * duration).round();
                  unawaited(_seekTimeline(at));
                },
                child: Container(
                  width: width,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.fromLTRB(8, 5, 8, 4),
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primaryContainer
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: selected ? colors.primary : colors.outlineVariant,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${index + 1}. ${item.isImage ? 'Photo: ' : ''}${item.name}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600,
                            color: selected
                                ? colors.onPrimaryContainer : colors.onSurface,
                          )),
                      const Spacer(),
                      Text(_time(duration) +
                          (item.overlayPath != null ? ' • Layer' : ''),
                          style: TextStyle(fontSize: 11,
                              color: selected ? colors.onPrimaryContainer
                                  : colors.onSurfaceVariant)),
                      const SizedBox(height: 3),
                      LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: colors.surface,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
      ]),
    );
  }

  Widget _editPanel(EditorClip? clip) {
    final editable = clip != null && !_busy;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        Text(clip == null ? 'Edit clips'
            : 'Edit • ' + clip.name,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        const Text('Move the timeline playhead to a moment, then trim, '
            'split, or remove the selected clip.',
            style: TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 9),
        if (clip != null)
          Text('Start ' + _time(clip.start) + '   End ' + _time(clip.end) +
              '   Duration ' + _time(_clipDuration(clip))),
        const SizedBox(height: 9),
        Wrap(spacing: 8, runSpacing: 6, children: [
          if (clip?.isImage != true)
            OutlinedButton.icon(
              onPressed: editable ? _setIn : null,
              icon: const Icon(Icons.first_page),
              label: const Text('Trim start'),
            ),
          if (clip?.isImage != true)
            OutlinedButton.icon(
              onPressed: editable ? _setOut : null,
              icon: const Icon(Icons.last_page),
              label: const Text('Trim end'),
            ),
          OutlinedButton.icon(
            onPressed: editable ? _split : null,
            icon: const Icon(Icons.content_cut),
            label: const Text('Split'),
          ),
          OutlinedButton.icon(
            onPressed: editable ? _duplicate : null,
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Duplicate'),
          ),
          OutlinedButton.icon(
            onPressed: editable ? _remove : null,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
        ]),
        if (clip != null && clip.isImage) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Text('Photo duration'),
            Expanded(child: Slider(
              min: 1, max: 30,
              value: ((clip.end - clip.start) / 1000)
                  .clamp(1.0, 30.0).toDouble(),
              onChanged: editable ? (value) => setState(() {
                clip.end = clip.start + (value * 1000).round();
              }) : null,
              onChangeEnd: editable
                  ? (_) => unawaited(_save()) : null,
            )),
            Text(((clip.end - clip.start) / 1000).round().toString() + 's'),
          ]),
        ],
        if (clip != null && !clip.isImage) ...[
          const SizedBox(height: 9),
          Row(children: [
            const Text('Speed'),
            Expanded(child: Slider(
              min: 0.1, max: 3, divisions: 29,
              value: clip.speed.clamp(0.1, 3.0).toDouble(),
              onChanged: editable ? _setSpeed : null,
              onChangeEnd: editable
                  ? (_) => unawaited(_save()) : null,
            )),
            Text(clip.speed.toStringAsFixed(2) + '×'),
          ]),
        ],
        Wrap(spacing: 7, runSpacing: 5, children: [
          if (clip != null && !clip.isImage)
            OutlinedButton.icon(
              onPressed: editable ? () => _setSpeedAndSave(0.2) : null,
              icon: const Icon(Icons.slow_motion_video),
              label: const Text('Slow-mo 0.2×'),
            ),
          if (clip != null && !clip.isImage)
            OutlinedButton(
              onPressed: editable ? () => _setSpeedAndSave(1) : null,
              child: const Text('Normal 1×'),
            ),
          if (clip != null && !clip.isImage)
            OutlinedButton.icon(
              onPressed: editable ? _toggleReverse : null,
              icon: const Icon(Icons.flip_camera_android_outlined),
              label: Text(clip.reverse ? 'Reverse ON' : 'Reverse'),
            ),
        ]),
        if (clip?.reverse == true)
          const Text('Reverse is applied on export; the preview plays '
              'forward. Reverse clips are limited to 10 seconds.',
              style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
        const SizedBox(height: 10),
        const Text('Next: freeze frame and drag-to-trim '
            'handles on the timeline.',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
      ],
    );
  }

  Widget _canvasPanel(EditorClip? clip) {
    final editable = clip != null && !_busy;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        const Text('Canvas & framing',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        const Text('Pinch the preview to zoom and drag it to pan. '
            'See your framing while changing these controls.',
            style: TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          OutlinedButton.icon(
            onPressed: editable ? _resetFrame : null,
            icon: const Icon(Icons.center_focus_strong),
            label: const Text('Reset'),
          ),
          OutlinedButton.icon(
            onPressed: editable
                ? () => _change((c) => c.turns = (c.turns + 1) % 4)
                : null,
            icon: const Icon(Icons.rotate_right),
            label: const Text('Rotate 90°'),
          ),
        ]),
        Row(children: [
          const Text('Zoom'),
          Expanded(child: Slider(
            min: 1, max: 3,
            value: (clip?.zoom ?? 1).clamp(1.0, 3.0).toDouble(),
            onChanged: editable
                ? (value) => setState(() => clip.zoom = value) : null,
            onChangeEnd: editable ? (_) => unawaited(_save()) : null,
          )),
          Text((clip?.zoom ?? 1).toStringAsFixed(1) + '×'),
        ]),
        Row(children: [
          const Text('Output ratio'),
          const SizedBox(width: 16),
          DropdownButton<String>(
            value: _ratio,
            items: const [
              DropdownMenuItem(value: '16:9', child: Text('16:9 Landscape')),
              DropdownMenuItem(value: '9:16', child: Text('9:16 Portrait')),
              DropdownMenuItem(value: '1:1', child: Text('1:1 Square')),
            ],
            onChanged: _busy ? null : (value) {
              if (value == null) return;
              setState(() => _ratio = value);
              unawaited(_save());
            },
          ),
        ]),
      ],
    );
  }

  Widget _colorPanel(EditorClip? clip) {
    final editable = clip != null && !_busy;
    if (clip == null) {
      return const Center(child: Text('Import a clip to adjust its color'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        Row(children: [
          const Expanded(child: Text('Light & clarity',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          TextButton.icon(
            onPressed: editable ? () => _change((c) {
              c.brightness = 0;
              c.contrast = 1;
              c.saturation = 1;
              c.clarity = 0;
            }) : null,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset'),
          ),
        ]),
        Row(children: [
          const SizedBox(width: 86, child: Text('Brightness')),
          Expanded(child: Slider(
            min: -0.5, max: 0.5,
            value: clip.brightness.clamp(-0.5, 0.5).toDouble(),
            onChanged: editable
                ? (v) => setState(() => clip.brightness = v) : null,
            onChangeEnd: editable ? (_) => unawaited(_save()) : null,
          )),
          SizedBox(width: 35, child: Text(
              clip.brightness.toStringAsFixed(2),
              style: const TextStyle(fontSize: 11))),
        ]),
        Row(children: [
          const SizedBox(width: 86, child: Text('Contrast')),
          Expanded(child: Slider(
            min: 0.5, max: 1.5,
            value: clip.contrast.clamp(0.5, 1.5).toDouble(),
            onChanged: editable
                ? (v) => setState(() => clip.contrast = v) : null,
            onChangeEnd: editable ? (_) => unawaited(_save()) : null,
          )),
          SizedBox(width: 35, child: Text(
              clip.contrast.toStringAsFixed(2),
              style: const TextStyle(fontSize: 11))),
        ]),
        Row(children: [
          const SizedBox(width: 86, child: Text('Saturation')),
          Expanded(child: Slider(
            min: 0, max: 2,
            value: clip.saturation.clamp(0.0, 2.0).toDouble(),
            onChanged: editable
                ? (v) => setState(() => clip.saturation = v) : null,
            onChangeEnd: editable ? (_) => unawaited(_save()) : null,
          )),
          SizedBox(width: 35, child: Text(
              clip.saturation.toStringAsFixed(2),
              style: const TextStyle(fontSize: 11))),
        ]),
        Row(children: [
          const SizedBox(width: 86, child: Text('Clarity')),
          Expanded(child: Slider(
            min: 0, max: 1.5,
            value: clip.clarity.clamp(0.0, 1.5).toDouble(),
            onChanged: editable
                ? (v) => setState(() => clip.clarity = v) : null,
            onChangeEnd: editable ? (_) => unawaited(_save()) : null,
          )),
          SizedBox(width: 35, child: Text(
              clip.clarity.toStringAsFixed(2),
              style: const TextStyle(fontSize: 11))),
        ]),
        const Text('Brightness, contrast, and saturation preview live. '
            'Clarity sharpening is applied on export.',
            style: TextStyle(fontSize: 11, color: Colors.white70)),
      ],
    );
  }

  Widget _layersPanel(EditorClip? clip) {
    final editable = clip != null && !_busy;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        const Text('Photo overlay layer',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('Add a picture over the selected video or photo. '
            'Drag the layer on the preview and pinch to resize.',
            style: TextStyle(fontSize: 12, color: Colors.white70)),
        const SizedBox(height: 9),
        Wrap(spacing: 8, runSpacing: 6, children: [
          OutlinedButton.icon(
            onPressed: editable ? () => unawaited(_addPhotoOverlay()) : null,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(clip?.overlayPath == null
                ? 'Add photo layer' : 'Replace photo layer'),
          ),
          OutlinedButton.icon(
            onPressed: editable && clip.overlayPath != null
                ? _removeOverlay : null,
            icon: const Icon(Icons.layers_clear),
            label: const Text('Remove layer'),
          ),
        ]),
        if (clip != null && clip.overlayPath != null) ...[
          Row(children: [
            const Text('Size'),
            Expanded(child: Slider(
              min: 0.1, max: 0.9,
              value: clip.overlaySize.clamp(0.1, 0.9).toDouble(),
              onChanged: editable
                  ? (v) => setState(() => clip.overlaySize = v) : null,
              onChangeEnd: editable ? (_) => unawaited(_save()) : null,
            )),
            Text((clip.overlaySize * 100).round().toString() + '%'),
          ]),
          Row(children: [
            const Text('Opacity'),
            Expanded(child: Slider(
              min: 0.1, max: 1,
              value: clip.overlayOpacity.clamp(0.1, 1.0).toDouble(),
              onChanged: editable
                  ? (v) => setState(() => clip.overlayOpacity = v) : null,
              onChangeEnd: editable ? (_) => unawaited(_save()) : null,
            )),
            Text((clip.overlayOpacity * 100).round().toString() + '%'),
          ]),
        ],
        const SizedBox(height: 8),
        const Text('This first layer lasts for the selected clip. '
            'Multiple independent video tracks are next.',
            style: TextStyle(fontSize: 11, color: Colors.white54)),
      ],
    );
  }

  Widget _transitionPanel() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        const Text('Transitions between clips',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        const Text('Choose how consecutive clips connect. '
            'The transition appears in the exported video; '
            'live timeline preview still cuts between clips.',
            style: TextStyle(fontSize: 12, color: Colors.white70)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final kind in const ['None', 'Fade', 'Wipe'])
            ChoiceChip(
              label: Text(kind == 'Wipe' ? 'Wipe left' : kind),
              selected: _transition == kind,
              onSelected: _busy ? null : (_) {
                setState(() => _transition = kind);
                unawaited(_save());
              },
            ),
        ]),
        if (_transition != 'None')
          Row(children: [
            const Text('Duration'),
            Expanded(child: Slider(
              min: 0.25, max: 1, divisions: 3,
              value: _transitionSeconds.clamp(0.25, 1).toDouble(),
              onChanged: _busy ? null : (value) =>
                  setState(() => _transitionSeconds = value),
              onChangeEnd: _busy
                  ? null : (_) => unawaited(_save()),
            )),
            Text(_transitionSeconds.toStringAsFixed(2) + 's'),
          ]),
        const SizedBox(height: 8),
        Text(_clips.length.toString() + ' clips • ' +
            (_clips.length < 2 ? 'Import two or more clips.' :
                'Applies at each clip boundary.'),
            style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ],
    );
  }

  Widget _plannedPanel(String title, List<String> features) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        Row(children: [
          Expanded(child: Text(title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold))),
          const Chip(
            visualDensity: VisualDensity.compact,
            label: Text('Planned', style: TextStyle(fontSize: 11)),
          ),
        ]),
        const SizedBox(height: 4),
        const Text('This menu shows the tools we are developing. '
            'They do not change the exported video yet.',
            style: TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final feature in features)
            Chip(label: Text(feature)),
        ]),
      ],
    );
  }

  Widget _selectedToolPanel(EditorClip? clip) {
    switch (_section) {
      case 'Canvas':
        return _canvasPanel(clip);
      case 'Adjust':
        return _colorPanel(clip);
      case 'Layers':
        return _layersPanel(clip);
      case 'Clips':
        return _timelinePanel(clip);
      case 'Transition':
        return _transitionPanel();
      case 'Beauty':
        return _plannedPanel('Face & skin beauty', const [
          'Smooth skin', 'Face shape', 'Jawline', 'Eyes', 'Nose',
          'Skin tone', 'Teeth',
        ]);
      case 'Makeup':
        return _plannedPanel('Makeup', const [
          'Foundation', 'Lip color', 'Blush', 'Eyeshadow', 'Eyeliner',
          'Eyebrows', 'Eyelashes', 'Save makeup style',
        ]);
      case 'Body':
        return _plannedPanel('Body adjustments', const [
          'Slim waist', 'Shape hips', 'Arms', 'Legs', 'Shoulders',
          'Height', 'Motion tracking',
        ]);
      case 'Retouch':
        return _plannedPanel('Tracked removal', const [
          'Small blemishes', 'Scars', 'Tattoos', 'Large skin areas',
          'Unwanted objects', 'Track mask through video',
        ]);
      case 'Audio':
        return _plannedPanel('Audio', const [
          'Volume', 'Mute', 'Music', 'Voiceover', 'Fade in / out',
          'Noise removal',
        ]);
      case 'Effects':
        return _plannedPanel('Effects & color', const [
          'Filters', 'Brightness', 'Contrast', 'Transitions',
          'Speed', 'Stabilization', 'Text & captions',
        ]);
      default:
        return _editPanel(clip);
    }
  }

  Widget _toolCategoryBar() {
    const categories = <(String, IconData)>[
      ('Edit', Icons.content_cut),
      ('Canvas', Icons.crop_rotate),
      ('Adjust', Icons.tune),
      ('Layers', Icons.layers_outlined),
      ('Clips', Icons.view_timeline),
      ('Transition', Icons.animation),
      ('Beauty', Icons.face_retouching_natural),
      ('Makeup', Icons.brush),
      ('Body', Icons.accessibility_new),
      ('Retouch', Icons.healing),
      ('Audio', Icons.music_note),
      ('Effects', Icons.auto_awesome),
    ];
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 70,
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
          for (final item in categories)
            InkWell(
              onTap: () => setState(() => _section = item.$1),
              child: Container(
                width: 74,
                decoration: BoxDecoration(
                  color: _section == item.$1
                      ? colors.primaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                margin: const EdgeInsets.symmetric(
                    horizontal: 2, vertical: 4),
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(item.$2, size: 23,
                        color: _section == item.$1
                            ? colors.onPrimaryContainer : colors.onSurface),
                    const SizedBox(height: 3),
                    Text(item.$1, style: TextStyle(
                        fontSize: 11,
                        fontWeight: _section == item.$1
                            ? FontWeight.bold : FontWeight.normal,
                        color: _section == item.$1
                            ? colors.onPrimaryContainer : colors.onSurface)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _timelinePanel(EditorClip? clip) {
    final totalMs = _timelineLength;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          const Expanded(
            child: Text('Clips play from top to bottom',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          Text(_clips.length.toString() + ' clips • ' + _time(totalMs)),
        ]),
      ),
      Expanded(
        child: _clips.isEmpty
            ? const Center(child: Text('Import clips to build a timeline'))
            : ListView.builder(
                itemCount: _clips.length,
                itemBuilder: (context, index) {
                  final item = _clips[index];
                  final selected = item.id == clip?.id;
                  return Card(
                    color: selected
                        ? Theme.of(context).colorScheme.primaryContainer
                        : null,
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Text((index + 1).toString()),
                      ),
                      title: Text(item.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_time(_clipDuration(item)) +
                          ' • Tap to edit this clip'),
                      onTap: _busy ? null : () {
                        setState(() => _section = 'Edit');
                        unawaited(_open(item));
                      },
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Move this clip earlier in the finished video',
                          onPressed: _busy || index == 0 ? null : () {
                            setState(() {
                              _clips.removeAt(index);
                              _clips.insert(index - 1, item);
                            });
                            unawaited(_save());
                          },
                          icon: const Icon(Icons.arrow_upward),
                        ),
                        IconButton(
                          tooltip: 'Move this clip later in the finished video',
                          onPressed: _busy || index == _clips.length - 1
                              ? null : () {
                            setState(() {
                              _clips.removeAt(index);
                              _clips.insert(index + 1, item);
                            });
                            unawaited(_save());
                          },
                          icon: const Icon(Icons.arrow_downward),
                        ),
                      ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final clip = _active;
    final player = _player;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Droid Vid Editor', style: TextStyle(fontSize: 18)),
            Text(_projectName, maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Saved projects',
            onPressed: _busy ? null : () => unawaited(_showProjects()),
            icon: const Icon(Icons.folder_open_outlined),
          ),
          IconButton(
            tooltip: 'Save current project',
            onPressed: _busy ? null : () => unawaited(_save()),
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          _videoFrame(clip, player),
          _previewControls(),
          _clipStrip(),
          Expanded(child: _selectedToolPanel(clip)),
          _toolCategoryBar(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_message, maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (_error != null)
                  Text(_error!,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.orangeAccent)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: FilledButton.icon(
                onPressed: _busy ? null : () => unawaited(_import()),
                icon: const Icon(Icons.add),
                label: const Text('Import'),
              )),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.icon(
                onPressed: _busy || _clips.isEmpty
                    ? null : () => unawaited(_export()),
                icon: const Icon(Icons.file_upload_outlined),
                label: const Text('Export MP4'),
              )),
              if (_busy && _sessionId != null)
                IconButton(
                  tooltip: 'Cancel export',
                  onPressed: _cancelExport,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
