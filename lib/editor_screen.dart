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
  int _panel = 0;
  double _gestureStartZoom = 1;

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


  void _onVideoGestureStart(EditorClip clip) {
    _gestureStartZoom = clip.zoom;
    final player = _player;
    if (player != null && player.value.isPlaying) {
      unawaited(player.pause());
    }
  }

  void _onVideoGestureUpdate(
      EditorClip clip, ScaleUpdateDetails details, Size frame) {
    if (_busy) return;
    final video = _player;
    if (video == null || !video.value.isInitialized) return;
    final rotatedAspect = clip.turns.isOdd
        ? 1 / video.value.aspectRatio
        : video.value.aspectRatio;
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
              if (clip == null || player == null ||
                  !player.value.isInitialized) {
                return Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: const Text('Import a video to preview it'),
                );
              }
              final video = player;
              final sourceSize = video.value.size;
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
                              child: RotatedBox(
                                quarterTurns: clip.turns,
                                child: VideoPlayer(video),
                              ),
                            ),
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

  Widget _previewControls(EditorClip? clip, VideoPlayerController? player) {
    if (clip == null || player == null) {
      return const SizedBox(height: 54);
    }
    return SizedBox(
      height: 54,
      child: Row(children: [
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
        Expanded(child: Slider(
          min: clip.start.toDouble(),
          max: clip.end.toDouble(),
          value: _at.clamp(clip.start, clip.end).toDouble(),
          onChanged: _busy ? null
              : (v) => unawaited(_seek(v.round())),
        )),
        Text(_time(_at)),
        const SizedBox(width: 8),
      ]),
    );
  }

  Widget _adjustPanel(EditorClip? clip) {
    final editable = clip != null && !_busy;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      children: [
        const Text('Touch the video above to reframe it.',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text('Pinch with two fingers to zoom. Drag with one finger '
            'to reposition the enlarged picture. The final MP4 uses '
            'these framing settings.',
            style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 4, children: [
          OutlinedButton.icon(
            onPressed: editable ? _resetFrame : null,
            icon: const Icon(Icons.center_focus_strong),
            label: const Text('Reset picture'),
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
            onChanged: editable ? (value) =>
                setState(() => clip.zoom = value) : null,
            onChangeEnd: editable ? (_) => unawaited(_save()) : null,
          )),
          Text((clip?.zoom ?? 1).toStringAsFixed(1) + '×'),
        ]),
        Row(children: [
          const Text('Crop / output'),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _ratio,
            items: const [
              DropdownMenuItem(value: '16:9', child: Text('16:9')),
              DropdownMenuItem(value: '9:16', child: Text('9:16')),
              DropdownMenuItem(value: '1:1', child: Text('1:1')),
            ],
            onChanged: _busy ? null : (value) {
              if (value == null) return;
              setState(() => _ratio = value);
              unawaited(_save());
            },
          ),
        ]),
        const Divider(),
        Text(clip == null ? 'Import a clip to begin trimming.'
            : 'In ' + _time(clip.start) +
              '   Out ' + _time(clip.end) +
              '   Length ' + _time(clip.end - clip.start)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 4, children: [
          OutlinedButton(
            onPressed: editable ? _setIn : null,
            child: const Text('Set start'),
          ),
          OutlinedButton(
            onPressed: editable ? _setOut : null,
            child: const Text('Set end'),
          ),
          OutlinedButton(
            onPressed: editable ? _split : null,
            child: const Text('Split here'),
          ),
          OutlinedButton(
            onPressed: editable ? _remove : null,
            child: const Text('Remove clip'),
          ),
        ]),
      ],
    );
  }

  Widget _timelinePanel(EditorClip? clip) {
    final totalMs = _clips.fold<int>(0, (sum, c) => sum + c.end - c.start);
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
                      subtitle: Text(_time(item.end - item.start) +
                          ' • Tap to edit picture'),
                      onTap: _busy ? null : () {
                        setState(() => _panel = 0);
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
          _videoFrame(clip, player),
          _previewControls(clip, player),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              ChoiceChip(
                label: const Text('Adjust picture'),
                selected: _panel == 0,
                onSelected: (_) => setState(() => _panel = 0),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Clip order'),
                selected: _panel == 1,
                onSelected: (_) => setState(() => _panel = 1),
              ),
            ]),
          ),
          Expanded(child: _panel == 0
              ? _adjustPanel(clip)
              : _timelinePanel(clip)),
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
