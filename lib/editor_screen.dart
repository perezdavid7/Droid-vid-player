// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
      {this.turns = 0, this.zoom = 1, this.x = 0.5, this.y = 0.5});
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

  EditorClip duplicate(int newId) =>
      EditorClip(newId, path, name, length, start, end,
          turns: turns, zoom: zoom, x: x, y: y);

  Map<String, Object> toJson() => {
    'id': id, 'path': path, 'name': name, 'length': length,
    'start': start, 'end': end, 'turns': turns, 'zoom': zoom,
    'x': x, 'y': y,
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
  );
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});
  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _clips = <EditorClip>[];
  VideoPlayerController? _player;
  int? _activeId;
  int _at = 0;
  int _nextId = 1;
  int _generation = 0;
  int? _sessionId;
  bool _busy = false;
  bool _cancelled = false;
  String _ratio = '16:9';
  String _message = 'Import local videos to start. Originals stay untouched.';
  String? _error;

  EditorClip? get _active {
    for (final c in _clips) {
      if (c.id == _activeId) return c;
    }
    return null;
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

  Future<File> _draft() async =>
      File(p.join((await _root()).path, 'current_project.json'));

  Future<void> _save() async {
    try {
      final file = await _draft();
      final temp = File(file.path + '.partial');
      await temp.writeAsString(jsonEncode({
        'version': 1,
        'ratio': _ratio,
        'clips': _clips.map((c) => c.toJson()).toList(),
      }), flush: true);
      await temp.rename(file.path);
    } catch (error) {
      if (mounted) setState(() => _error = 'Save failed: $error');
    }
  }

  Future<void> _load() async {
    try {
      final file = await _draft();
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['clips'] is! List) return;
      final restored = <EditorClip>[];
      for (final raw in data['clips'] as List) {
        try {
          final clip = EditorClip.fromJson(Map<String, dynamic>.from(raw as Map));
          if (clip.start >= 0 && clip.end > clip.start &&
              clip.end <= clip.length && await File(clip.path).exists()) {
            restored.add(clip);
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _clips.addAll(restored);
        if (const ['16:9', '9:16', '1:1'].contains(data['ratio'])) {
          _ratio = data['ratio'] as String;
        }
        for (final c in _clips) {
          if (c.id >= _nextId) _nextId = c.id + 1;
        }
        _message = 'Restored ' + restored.length.toString() + ' saved clips.';
      });
      if (_clips.isNotEmpty) await _open(_clips.first);
    } catch (error) {
      if (mounted) setState(() => _error = 'Load failed: $error');
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _player?.removeListener(_watch);
    final old = _player;
    if (old != null) unawaited(old.dispose());
    super.dispose();
  }

  Future<void> _open(EditorClip clip) async {
    if (_busy) return;
    final generation = ++_generation;
    final old = _player;
    _player = null;
    old?.removeListener(_watch);
    if (old != null) await old.dispose();
    if (!mounted || generation != _generation) return;
    setState(() {
      _activeId = clip.id;
      _at = clip.start;
      _error = null;
    });
    final next = VideoPlayerController.file(File(clip.path));
    try {
      await next.initialize().timeout(const Duration(seconds: 25));
      if (!mounted || generation != _generation) {
        await next.dispose();
        return;
      }
      await next.seekTo(Duration(milliseconds: clip.start));
      next.addListener(_watch);
      setState(() => _player = next);
    } catch (error) {
      await next.dispose();
      if (mounted && generation == _generation) {
        setState(() => _error = 'Preview failed: $error');
      }
    }
  }

  void _watch() {
    final clip = _active;
    final player = _player;
    if (!mounted || clip == null || player == null) return;
    final current = player.value.position.inMilliseconds;
    if (current >= clip.end && player.value.isPlaying) {
      unawaited(player.pause());
    }
    if ((current - _at).abs() >= 100) {
      setState(() => _at = current.clamp(clip.start, clip.end));
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

  Future<void> _import() async {
    if (_busy) return;
    final chosen = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'mp4', 'm4v', 'mov', 'mkv', 'avi', 'webm',
        'mpeg', 'mpg', 'mts', 'm2ts', 'ts', 'vob', 'wmv',
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
          probe = VideoPlayerController.file(copy);
          await probe.initialize().timeout(const Duration(seconds: 25));
          final duration = probe.value.duration.inMilliseconds;
          if (duration < 500) throw StateError('No usable frames');
          additions.add(EditorClip(
              _nextId++, copy.path, item.name, duration, 0, duration));
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
        _at <= clip.start + 300 || _at >= clip.end - 300) return;
    setState(() {
      final second = clip.duplicate(_nextId++);
      second.start = _at;
      clip.end = _at;
      _clips.insert(_clips.indexOf(clip) + 1, second);
      _message = 'Split complete. Both pieces are retained.';
    });
    unawaited(_save());
  }

  void _move(int direction) {
    final clip = _active;
    if (clip == null || _busy) return;
    final from = _clips.indexOf(clip);
    final to = from + direction;
    if (to < 0 || to >= _clips.length) return;
    setState(() {
      _clips.removeAt(from);
      _clips.insert(to, clip);
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

  void _cancelExport() {
    _cancelled = true;
    final id = _sessionId;
    if (id != null) unawaited(FFmpegKit.cancel(id));
    if (mounted) setState(() => _message = 'Cancelling export…');
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
      await _player?.pause();
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
      for (var i = 0; i < _clips.length; i++) {
        if (_cancelled) throw StateError('Export cancelled');
        final clip = _clips[i];
        if (mounted) {
          setState(() => _message =
              'Rendering clip ' + (i + 1).toString() +
              ' of ' + _clips.length.toString() + '…');
        }
        final filters = <String>[
          ...List.filled(clip.turns % 4, 'transpose=1'),
          'crop=iw/' + clip.zoom.toStringAsFixed(3) +
              ':ih/' + clip.zoom.toStringAsFixed(3) +
              ':(iw-ow)*' + clip.x.toStringAsFixed(3) +
              ':(ih-oh)*' + clip.y.toStringAsFixed(3),
          'scale=' + size[0].toString() + ':' + size[1].toString() +
              ':force_original_aspect_ratio=increase',
          'crop=' + size[0].toString() + ':' + size[1].toString(),
          'setsar=1',
        ].join(',');
        final output = p.join(work.path,
            stamp + '_clip_' + i.toString() + '.mp4');
        final audio = await _hasAudio(clip.path);
        final arguments = <String>[
          '-hide_banner', '-nostdin', '-loglevel', 'error',
          '-i', clip.path,
          if (!audio) ...[
            '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo',
          ],
          '-ss', (clip.start / 1000).toStringAsFixed(3),
          '-t', ((clip.end - clip.start) / 1000).toStringAsFixed(3),
          '-map', '0:v:0', '-map', audio ? '0:a:0' : '1:a:0',
          '-vf', filters,
          '-r', '30', '-fps_mode', 'cfr',
          '-c:v', 'mpeg4', '-q:v', '2', '-threads:v', '2',
          '-pix_fmt', 'yuv420p',
          '-c:a', 'aac', '-b:a', '160k', '-ar', '44100', '-ac', '2',
          '-y', output,
        ];
        if (!await _run(arguments) || !await File(output).exists()) {
          throw StateError('Could not encode clip ' + (i + 1).toString());
        }
        parts.add(output);
      }
      if (_cancelled) throw StateError('Export cancelled');
      final partial = File(p.join(exports.path,
          'DroidVidEditor_' + stamp + '.partial.mp4'));
      if (parts.length == 1) {
        await File(parts.first).copy(partial.path);
      } else {
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
      if (mounted) setState(() => _message = message);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _button(String label, VoidCallback? onPressed) =>
      OutlinedButton(onPressed: onPressed, child: Text(label));

  @override
  Widget build(BuildContext context) {
    final clip = _active;
    final player = _player;
    final editable = clip != null && !_busy;
    final totalMs = _clips.fold<int>(0, (sum, c) => sum + c.end - c.start);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Droid Vid Editor'),
        actions: [
          IconButton(
            tooltip: 'Save current project',
            onPressed: _busy ? null : () => unawaited(_save()),
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Container(
                  height: 245,
                  clipBehavior: Clip.hardEdge,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: player != null && player.value.isInitialized
                      ? Center(
                          child: Transform.translate(
                            offset: Offset(
                              (0.5 - (clip?.x ?? 0.5)) *
                                  120 * ((clip?.zoom ?? 1) - 1),
                              (0.5 - (clip?.y ?? 0.5)) *
                                  120 * ((clip?.zoom ?? 1) - 1),
                            ),
                            child: Transform.scale(
                              scale: clip?.zoom ?? 1,
                              child: RotatedBox(
                                quarterTurns: clip?.turns ?? 0,
                                child: AspectRatio(
                                  aspectRatio: player.value.aspectRatio,
                                  child: VideoPlayer(player),
                                ),
                              ),
                            ),
                          ),
                        )
                      : const Center(
                          child: Text('Import a video to preview it')),
                ),
                if (clip != null && player != null) ...[
                  Row(children: [
                    IconButton(
                      tooltip: player.value.isPlaying ? 'Pause' : 'Play',
                      onPressed: _busy ? null : () async {
                        if (player.value.isPlaying) {
                          await player.pause();
                        } else {
                          if (_at >= clip.end - 100) await _seek(clip.start);
                          await player.play();
                        }
                        if (mounted) setState(() {});
                      },
                      icon: Icon(player.value.isPlaying
                          ? Icons.pause : Icons.play_arrow),
                    ),
                    Expanded(
                      child: Slider(
                        min: clip.start.toDouble(),
                        max: clip.end.toDouble(),
                        value: _at.clamp(clip.start, clip.end).toDouble(),
                        onChanged: _busy
                            ? null : (v) => unawaited(_seek(v.round())),
                      ),
                    ),
                    Text(_time(_at)),
                  ]),
                  Text('In ' + _time(clip.start) +
                      ' · Out ' + _time(clip.end) +
                      ' · Length ' + _time(clip.end - clip.start)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 5, runSpacing: 4, children: [
                    _button('Set in', editable ? _setIn : null),
                    _button('Set out', editable ? _setOut : null),
                    _button('Split', editable ? _split : null),
                    _button('Rotate 90°', editable
                        ? () => _change((c) => c.turns = (c.turns + 1) % 4)
                        : null),
                    _button('Move left', editable ? () => _move(-1) : null),
                    _button('Move right', editable ? () => _move(1) : null),
                    _button('Remove', editable ? _remove : null),
                  ]),
                  const SizedBox(height: 10),
                  const Text('Static reframe',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Row(children: [
                    const SizedBox(width: 56, child: Text('Zoom')),
                    Expanded(child: Slider(
                      min: 1, max: 3,
                      value: clip.zoom.clamp(1.0, 3.0).toDouble(),
                      onChanged: editable
                          ? (v) => setState(() => clip.zoom = v) : null,
                      onChangeEnd: editable
                          ? (_) => unawaited(_save()) : null,
                    )),
                    Text(clip.zoom.toStringAsFixed(1)),
                  ]),
                  Row(children: [
                    const SizedBox(width: 56, child: Text('Pan X')),
                    Expanded(child: Slider(
                      min: 0, max: 1,
                      value: clip.x.clamp(0.0, 1.0).toDouble(),
                      onChanged: editable
                          ? (v) => setState(() => clip.x = v) : null,
                      onChangeEnd: editable
                          ? (_) => unawaited(_save()) : null,
                    )),
                  ]),
                  Row(children: [
                    const SizedBox(width: 56, child: Text('Pan Y')),
                    Expanded(child: Slider(
                      min: 0, max: 1,
                      value: clip.y.clamp(0.0, 1.0).toDouble(),
                      onChanged: editable
                          ? (v) => setState(() => clip.y = v) : null,
                      onChangeEnd: editable
                          ? (_) => unawaited(_save()) : null,
                    )),
                  ]),
                ],
                const SizedBox(height: 10),
                Row(children: [
                  const Text('Crop/output: '),
                  DropdownButton<String>(
                    value: _ratio,
                    items: const [
                      DropdownMenuItem(value: '16:9', child: Text('16:9')),
                      DropdownMenuItem(value: '9:16', child: Text('9:16')),
                      DropdownMenuItem(value: '1:1', child: Text('1:1')),
                    ],
                    onChanged: _busy ? null : (choice) {
                      if (choice == null) return;
                      setState(() => _ratio = choice);
                      unawaited(_save());
                    },
                  ),
                  const Spacer(),
                  Text(_clips.length.toString() + ' clips · ' + _time(totalMs)),
                ]),
                const Text('Timeline — tap clips to edit'),
                const SizedBox(height: 5),
                SizedBox(
                  height: 102,
                  child: _clips.isEmpty
                      ? const Center(child: Text('No clips imported'))
                      : ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: _clips.length,
                          itemBuilder: (context, index) {
                            final item = _clips[index];
                            final selected = item.id == _activeId;
                            return SizedBox(
                              width: 168,
                              child: Card(
                                color: selected
                                    ? Theme.of(context).colorScheme.primaryContainer
                                    : null,
                                child: InkWell(
                                  onTap: _busy ? null
                                      : () => unawaited(_open(item)),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text((index + 1).toString() +
                                            '. ' + item.name,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis),
                                        const Spacer(),
                                        Text(_time(item.end - item.start)),
                                        const LinearProgressIndicator(value: 1),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 10),
                Text(_message),
                if (_error != null)
                  Text(_error!,
                      style: const TextStyle(color: Colors.orangeAccent)),
                const SizedBox(height: 12),
                const Text('Planned next: animated keyframes, tracked masks, '
                    'face and body beauty controls, makeup, and AI removal '
                    'of blemishes, tattoos, and unwanted objects.',
                    style: TextStyle(color: Colors.white60)),
                const SizedBox(height: 10),
                const Text('Privacy: files stay on this device. Imported '
                    'media is copied into private project storage; '
                    'originals are never modified.',
                    style: TextStyle(color: Colors.white60)),
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
