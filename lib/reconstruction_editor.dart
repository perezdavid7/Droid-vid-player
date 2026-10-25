import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'recovery_destination.dart';

class _Piece {
  final int id;
  final String path;
  int start;
  int end;
  int group;
  bool excluded;
  _Piece(this.id, this.path, this.start, this.end, this.group,
      {this.excluded = false});
  Map<String, dynamic> toJson() => {
    'id': id, 'path': path, 'start': start, 'end': end,
    'group': group, 'excluded': excluded,
  };
  static _Piece? decode(dynamic value) {
    if (value is! Map) return null;
    if (value['id'] is! int || value['path'] is! String ||
        value['start'] is! int || value['end'] is! int ||
        value['group'] is! int) { return null; }
    return _Piece(value['id'] as int, value['path'] as String,
        value['start'] as int, value['end'] as int, value['group'] as int,
        excluded: value['excluded'] == true);
  }
}

/// A saved edit decision list; video sources are never overwritten or moved.
class ReconstructionEditor extends StatefulWidget {
  final List<String> segmentPaths;
  /// Attempt numbers shown in Saved Recoveries, keyed by recovery-run stem.
  final Map<String, int> attemptNumbers;
  const ReconstructionEditor({
    super.key,
    required this.segmentPaths,
    this.attemptNumbers = const {},
  });
  @override
  State<ReconstructionEditor> createState() => _ReconstructionEditorState();
}

class _ReconstructionEditorState extends State<ReconstructionEditor> {
  final _pieces = <_Piece>[];
  final _groups = <int, String>{1: 'Recording A', 2: 'Recording B'};
  final _lengths = <String, int>{};
  VideoPlayerController? _player;
  int? _activeId;
  int _nextId = 1;
  int _generation = 0;
  int _at = 0;
  int? _ffmpegSession;
  bool _loading = true;
  bool _busy = false;
  String? _notice;
  String? _error;
  String? _segmentFilter;
  bool _floating = false;
  Offset? _floatingPosition;

  int _segmentNumber(String path) {
    final match = RegExp(r'\.segment_(\d+)\.mkv$')
        .firstMatch(p.basename(path));
    final number = int.tryParse(match?.group(1) ?? '');
    return number == null ? 0 : number + 1;
  }

  String _segmentRun(String path) =>
      path.replaceFirst(RegExp(r'\.segment_\d+\.mkv$'), '');

  String _segmentLabel(String path) {
    final attempt = widget.attemptNumbers[_segmentRun(path)];
    final prefix = attempt == null ? '' : 'Attempt $attempt · ';
    return '${prefix}Segment ${_segmentNumber(path)}';
  }

  String _pieceLabel(_Piece piece) {
    final siblings = _pieces.where((x) => x.path == piece.path).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return '${_segmentLabel(piece.path)} · Part '
        '${siblings.indexOf(piece) + 1} of ${siblings.length}';
  }

  List<String> get _sourceSegments {
    final paths = _pieces.map((x) => x.path).toSet().toList();
    paths.sort((a, b) {
      final attemptA = widget.attemptNumbers[_segmentRun(a)] ?? 0;
      final attemptB = widget.attemptNumbers[_segmentRun(b)] ?? 0;
      final attemptOrder = attemptA.compareTo(attemptB);
      if (attemptOrder != 0) return attemptOrder;
      final numberOrder = _segmentNumber(a).compareTo(_segmentNumber(b));
      return numberOrder != 0 ? numberOrder : a.compareTo(b);
    });
    return paths;
  }

  List<_Piece> get _navigationPieces {
    final paths = _sourceSegments;
    final ordered = [..._pieces];
    ordered.sort((a, b) {
      final pathCompare = paths.indexOf(a.path).compareTo(paths.indexOf(b.path));
      return pathCompare != 0 ? pathCompare : a.start.compareTo(b.start);
    });
    return ordered;
  }

  void _jumpPiece(int delta) {
    if (_busy) return;
    final ordered = _navigationPieces;
    final index = ordered.indexWhere((x) => x.id == _activeId);
    final next = index + delta;
    if (index < 0 || next < 0 || next >= ordered.length) return;
    if (_segmentFilter != null) {
      setState(() => _segmentFilter = ordered[next].path);
    }
    unawaited(_open(ordered[next]));
  }

  void _chooseSegment(String? path) {
    if (_busy) return;
    setState(() => _segmentFilter = path);
    if (path == null) return;
    final sameSource = _navigationPieces.where((x) => x.path == path).toList();
    if (sameSource.isNotEmpty) unawaited(_open(sameSource.first));
  }


  _Piece? get _selected {
    for (final x in _pieces) {
      if (x.id == _activeId) return x;
    }
    return null;
  }

  String _clock(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    return '${duration.inMinutes.toString().padLeft(2, '0')}:'
        '${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}.'
        '${duration.inMilliseconds.remainder(1000) ~/ 100}';
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<File> _project() async {
    final dir = Directory(p.join(
        (await getApplicationDocumentsDirectory()).path,
        'DroidVidRecoveryProjects'));
    await dir.create(recursive: true);
    final roots = widget.segmentPaths.map(_segmentRun).toSet().toList()
      ..sort();
    // Keep the original single-attempt project name so existing edits load.
    // Combined attempts get their own stable project, without overwriting
    // edits previously saved for any individual recovery attempt.
    String root;
    if (roots.length == 1) {
      root = p.basename(roots.first);
    } else {
      final identity = roots.join('|');
      var hashA = 0x811c9dc5;
      var hashB = 5381;
      for (final unit in identity.codeUnits) {
        hashA = ((hashA ^ unit) * 0x01000193) & 0xffffffff;
        hashB = ((hashB * 33) ^ unit) & 0xffffffff;
      }
      root = 'combined_${roots.length}_'
          '${hashA.toRadixString(16).padLeft(8, '0')}_'
          '${hashB.toRadixString(16).padLeft(8, '0')}';
    }
    return File(p.join(dir.path, '$root.reconstruction.json'));
  }

  Future<void> _save() async {
    try {
      final file = await _project();
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode({
        'pieces': _pieces.map((x) => x.toJson()).toList(),
        'groups': {for (final entry in _groups.entries)
          '${entry.key}': entry.value},
      }), flush: true);
      await temp.rename(file.path);
    } catch (error) {
      if (mounted) setState(() => _error = 'Cannot save edits: $error');
    }
  }

  Future<void> _load() async {
    try {
      final sources = widget.segmentPaths.toSet().toList()..sort();
      for (final file in sources) {
        VideoPlayerController? controller;
        try {
          controller = VideoPlayerController.file(File(file));
          await controller.initialize()
              .timeout(const Duration(seconds: 12));
          _lengths[file] = controller.value.duration.inMilliseconds;
        } catch (_) {
          // Damaged segments remain in Saved Recoveries, never deleted.
        } finally {
          await controller?.dispose();
        }
      }
      final project = await _project();
      if (await project.exists()) {
        try {
          final data = jsonDecode(await project.readAsString());
          if (data is Map) {
            final names = data['groups'];
            if (names is Map) {
              for (final entry in names.entries) {
                final id = int.tryParse(entry.key.toString());
                if (id != null && id > 0 && entry.value is String) {
                  _groups[id] = entry.value as String;
                }
              }
            }
            final records = data['pieces'];
            if (records is List) {
              for (final value in records) {
                final piece = _Piece.decode(value);
                if (piece != null && _lengths.containsKey(piece.path) &&
                    piece.start >= 0 && piece.end > piece.start &&
                    piece.end <= _lengths[piece.path]!) {
                  _pieces.add(piece);
                }
              }
            }
          }
        } catch (_) {}
      }
      for (final piece in _pieces) {
        if (piece.id >= _nextId) _nextId = piece.id + 1;
        _groups.putIfAbsent(piece.group, () => 'Recording ${piece.group}');
      }
      // Newly recovered segments are added to existing projects without
      // disturbing previously saved cuts, exclusions or recording order.
      final loadedPaths = _pieces.map((piece) => piece.path).toSet();
      for (final file in sources) {
        final length = _lengths[file] ?? 0;
        if (length > 500 && loadedPaths.add(file)) {
          _pieces.add(_Piece(_nextId++, file, 0, length, 1));
        }
      }
      if (mounted) setState(() => _loading = false);
      if (_pieces.isNotEmpty) await _open(_pieces.first);
    } catch (error) {
      if (mounted) { setState(() {
        _loading = false;
        _error = '$error';
      }); }
    }
  }

  Future<void> _open(_Piece piece) async {
    if (_busy) return;
    final generation = ++_generation;
    final previous = _player;
    _player = null;
    previous?.removeListener(_positionChanged);
    await previous?.dispose();
    if (!mounted || generation != _generation) return;
    try {
      final controller = VideoPlayerController.file(File(piece.path));
      await controller.initialize();
      if (!mounted || generation != _generation) {
        await controller.dispose();
        return;
      }
      await controller.seekTo(Duration(milliseconds: piece.start));
      controller.addListener(_positionChanged);
      setState(() {
        _player = controller;
        _activeId = piece.id;
        _at = piece.start;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'Cannot preview clip: $error');
    }
  }


  /// A piece preview floats over the scrolling assignment lists, using
  /// the same video controller as the editor to avoid duplicate decoders.
  Future<void> _openFloating(_Piece piece) async {
    await _open(piece);
    if (!mounted || _selected?.id != piece.id || _player == null) return;
    setState(() {
      _floating = true;
      _floatingPosition = null;
    });
    await _player!.play();
    if (mounted) setState(() {});
  }

  Future<void> _togglePreviewPlayback({bool floatOnPlay = false}) async {
    final video = _player;
    if (_busy || video == null) return;
    if (video.value.isPlaying) {
      await video.pause();
    } else {
      if (floatOnPlay && mounted) setState(() => _floating = true);
      await video.play();
    }
    if (mounted && identical(video, _player)) setState(() {});
  }

  void _positionChanged() {
    final controller = _player;
    if (!mounted || controller == null) return;
    final current = controller.value.position.inMilliseconds;
    if ((current - _at).abs() >= 100) {
      setState(() => _at = current);
    }
    final piece = _selected;
    if (piece != null && current >= piece.end &&
        controller.value.isPlaying) {
      unawaited(controller.pause());
    }
  }

  Future<void> _seek(double position) async {
    final current = _selected;
    final controller = _player;
    if (current == null || controller == null) return;
    final target = position.round().clamp(current.start, current.end);
    setState(() => _at = target);
    await controller.seekTo(Duration(milliseconds: target));
  }

  void _change(void Function() action) {
    setState(action);
    unawaited(_save());
  }

  void _split() {
    final selected = _selected;
    if (selected == null || _busy) return;
    final cut = _at.clamp(selected.start, selected.end);
    if (cut <= selected.start + 350 || cut >= selected.end - 350) {
      setState(() => _notice = 'Move away from the clip edges before splitting.');
      return;
    }
    _change(() {
      final index = _pieces.indexOf(selected);
      final next = _Piece(_nextId++, selected.path, cut, selected.end,
          selected.group, excluded: selected.excluded);
      selected.end = cut;
      _pieces.insert(index + 1, next);
      _notice = 'Split at ${_clock(cut)}. Both pieces are retained.';
    });
  }

  void _reorder(_Piece piece, int delta) {
    final matches = _pieces.where((x) =>
        x.group == piece.group && !x.excluded).toList();
    final before = matches.indexOf(piece);
    final after = before + delta;
    if (after < 0 || after >= matches.length) return;
    _change(() {
      final first = _pieces.indexOf(piece);
      final second = _pieces.indexOf(matches[after]);
      _pieces[first] = matches[after];
      _pieces[second] = piece;
    });
  }

  Future<void> _rename(int id) async {
    final input = TextEditingController(text: _groups[id]);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recording name'),
        content: TextField(controller: input, maxLength: 40),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(onPressed: () =>
              Navigator.pop(ctx, input.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    input.dispose();
    if (updated != null && updated.isNotEmpty && mounted) {
      _change(() => _groups[id] = updated);
    }
  }

  Future<bool> _run(List<String> args) async {
    final done = Completer<bool>();
    int? id;
    try {
      final session = await FFmpegKit.executeWithArgumentsAsync(args,
          (finished) async {
        final result = await finished.getReturnCode();
        if (!done.isCompleted) {
          done.complete(ReturnCode.isSuccess(result));
        }
      });
      id = session.getSessionId();
      _ffmpegSession = id;
      return await done.future.timeout(const Duration(minutes: 8));
    } on TimeoutException {
      if (id != null) await FFmpegKit.cancel(id);
      return false;
    } catch (_) {
      return false;
    } finally {
      _ffmpegSession = null;
    }
  }

  Future<void> _export(int recording) async {
    if (_busy) return;
    final pieces = _pieces.where((x) =>
        x.group == recording && !x.excluded).toList();
    if (pieces.isEmpty) return;
    final destination = await RecoveryDestination.selectedUri();
    if (destination == null || destination.isEmpty) {
      if (mounted) { setState(() => _error =
          'Choose an export folder in Saved Recoveries first.'); }
      return;
    }
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Export ${_groups[recording]}?'),
        content: Text('Join ${pieces.length} pieces in the listed order. '
            'Accurate cuts require high-quality re-encoding and additional '
            'free storage. Original MKV segments stay untouched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Export')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = 'Preparing reconstruction…';
    });
    try {
      await _player?.pause();
      final docs = await getApplicationDocumentsDirectory();
      final scratch = Directory(p.join(docs.path, 'DroidVidRecoveries',
          'reconstruction_work'));
      await scratch.create(recursive: true);
      final job = '${recording}_${DateTime.now().millisecondsSinceEpoch}';
      final outputs = <String>[];
      for (var i = 0; i < pieces.length; i++) {
        final part = pieces[i];
        final output = p.join(scratch.path, '${job}_piece_$i.mkv');
        if (mounted) { setState(() =>
            _notice = 'Encoding piece ${i + 1} / ${pieces.length}…'); }
        final ok = await _run([
          '-hide_banner', '-nostdin', '-loglevel', 'error',
          '-threads', '2', '-i', part.path,
          '-ss', (part.start / 1000).toStringAsFixed(3),
          '-t', ((part.end - part.start) / 1000).toStringAsFixed(3),
          '-map', '0:v:0', '-map', '0:a:0?', '-sn', '-dn',
          '-vf', 'scale=720:480:force_original_aspect_ratio=decrease,'
              'pad=720:480:(ow-iw)/2:(oh-ih)/2,setsar=1',
          '-r', '30', '-fps_mode', 'cfr',
          '-c:v', 'mpeg4', '-q:v', '2', '-threads:v', '2',
          '-pix_fmt', 'yuv420p',
          '-c:a', 'aac', '-b:a', '192k',
          '-af', 'aresample=async=1000:first_pts=0',
          '-f', 'matroska', '-n', output,
        ]);
        if (!ok || !await File(output).exists()) {
          throw StateError('Could not encode piece ${i + 1}. '
              'Original segments remain untouched.');
        }
        outputs.add(output);
      }
      final safe = (_groups[recording] ?? 'Recording_$recording')
          .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final merged = p.join(docs.path, 'DroidVidRecoveries',
          '${safe}_reconstructed_${DateTime.now().millisecondsSinceEpoch}.mkv');
      if (outputs.length == 1) {
        await File(outputs.first).copy(merged);
      } else {
        final list = File(p.join(scratch.path, '$job.concat.txt'));
        final contents = outputs.map((x) =>
            "file '$x'").join('\n');
        await list.writeAsString('$contents\n', flush: true);
        if (!await _run([
          '-hide_banner', '-nostdin', '-loglevel', 'error',
          '-f', 'concat', '-safe', '0', '-i', list.path,
          '-c', 'copy', '-f', 'matroska', '-n', merged,
        ])) {
          throw StateError('The piece join failed. Encoded pieces were '
              'retained in reconstruction_work for investigation.');
        }
      }
      // Keep the private finished video on every failed or unverified export.
      // A full read-back comparison of the chosen SAF document must succeed
      // before removing this intermediate output.
      if (mounted) {
        setState(() => _notice =
            'Exporting and checking the full destination file…');
      }
      await RecoveryDestination.exportVerifiedReconstruction(merged);
      String resultMessage;
      try {
        await File(merged).delete();
        resultMessage = 'Export verified. Temporary finished video deleted. '
            'Original segments and reconstruction project preserved.';
      } catch (error) {
        resultMessage = 'Export verified, but the temporary app copy could '
            'not be removed: $error. You can safely review it later.';
      }
      if (mounted) { setState(() => _notice = resultMessage); }
      for (final output in outputs) {
        try { await File(output).delete(); } catch (_) {}
      }
      try { await File(p.join(scratch.path, '$job.concat.txt')).delete(); }
      catch (_) {}
    } catch (error) {
      if (mounted) setState(() => _error = 'Reconstruction failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    _player?.removeListener(_positionChanged);
    unawaited(_player?.dispose());
    if (_ffmpegSession != null) {
      unawaited(FFmpegKit.cancel(_ffmpegSession));
    }
    super.dispose();
  }

  Widget _segmentNavigator() {
    final segments = _sourceSegments;
    final ordered = _navigationPieces;
    final currentIndex = ordered.indexWhere((x) => x.id == _activeId);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        key: ValueKey(_segmentFilter),
        initialValue: _segmentFilter,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Jump to segment / filter pieces',
          border: OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem<String>(
            value: null, child: Text('All segments'),
          ),
          for (final path in segments)
            DropdownMenuItem<String>(
              value: path,
              child: Text('${_segmentLabel(path)}  '
                  '(${_pieces.where((x) => x.path == path).length} pieces)'),
            ),
        ],
        onChanged: _busy ? null : _chooseSegment,
      ),
      const SizedBox(height: 8),
      Row(children: [
        OutlinedButton.icon(
          onPressed: _busy || currentIndex <= 0 ? null :
              () => _jumpPiece(-1),
          icon: const Icon(Icons.chevron_left),
          label: const Text('Previous'),
        ),
        Expanded(child: Text(
          currentIndex >= 0
              ? '${currentIndex + 1} of ${ordered.length} pieces'
              : 'Select a piece',
          textAlign: TextAlign.center,
        )),
        OutlinedButton.icon(
          onPressed: _busy || currentIndex < 0 ||
              currentIndex >= ordered.length - 1 ? null :
              () => _jumpPiece(1),
          icon: const Icon(Icons.chevron_right),
          label: const Text('Next'),
        ),
      ]),
    ]);
  }

  Widget _preview() {
    final part = _selected;
    final video = _player;
    if (part == null) return const Text('No readable segments available.');
    final position = _at.clamp(part.start, part.end).toDouble();
    return Column(children: [
      Text(_pieceLabel(part),
          style: Theme.of(context).textTheme.titleMedium),
      if (_floating)
        OutlinedButton.icon(
          onPressed: () => setState(() => _floating = false),
          icon: const Icon(Icons.picture_in_picture_alt),
          label: const Text('Video is floating · Return to full preview'),
        )
      else if (video != null && video.value.isInitialized)
        AspectRatio(aspectRatio: video.value.aspectRatio,
            child: VideoPlayer(video))
      else const SizedBox(height: 120,
          child: Center(child: CircularProgressIndicator())),
      Slider(
        value: position, min: part.start.toDouble(), max: part.end.toDouble(),
        onChanged: _busy ? null : (value) => unawaited(_seek(value)),
      ),
      Text('${_clock(position.round())} / ${_clock(part.end)}'),
      Wrap(spacing: 6, children: [
        IconButton(
          tooltip: 'Play / pause',
          onPressed: video == null || _busy ? null : () =>
              unawaited(_togglePreviewPlayback(floatOnPlay: true)),
          icon: Icon(video?.value.isPlaying == true
              ? Icons.pause : Icons.play_arrow),
        ),
        FilledButton.tonal(
          onPressed: _busy ? null : _split,
          child: const Text('Split here'),
        ),
        OutlinedButton(
          onPressed: _busy ? null : () => _change(() =>
              part.start = position.round().clamp(0, part.end - 350)),
          child: const Text('Set start here'),
        ),
        OutlinedButton(
          onPressed: _busy ? null : () => _change(() =>
              part.end = position.round().clamp(
                  part.start + 350, _lengths[part.path]!)),
          child: const Text('Set end here'),
        ),
      ]),
    ]);
  }


  /// A draggable picture-in-picture preview stays fixed while the user
  /// scrolls, assigns pieces, and reorders the recording lists underneath.
  Widget _floatingPreview(BoxConstraints bounds) {
    final part = _selected;
    final video = _player;
    if (part == null) return const SizedBox.shrink();

    final width = math.min(280.0, math.max(160.0, bounds.maxWidth - 16));
    const estimatedHeight = 270.0;
    final maxLeft = math.max(8.0, bounds.maxWidth - width - 8);
    final maxTop = math.max(8.0, bounds.maxHeight - estimatedHeight - 8);
    final left = (_floatingPosition?.dx ?? maxLeft)
        .clamp(8.0, maxLeft).toDouble();
    final top = (_floatingPosition?.dy ?? 8.0)
        .clamp(8.0, maxTop).toDouble();
    final position = _at.clamp(part.start, part.end).toDouble();

    return Positioned(
      left: left,
      top: top,
      width: width,
      child: Material(
        elevation: 12,
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) {
                setState(() {
                  _floatingPosition = Offset(
                    (left + details.delta.dx).clamp(8.0, maxLeft).toDouble(),
                    (top + details.delta.dy).clamp(8.0, maxTop).toDouble(),
                  );
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                child: Row(children: [
                  const Icon(Icons.drag_indicator, size: 19),
                  const SizedBox(width: 5),
                  Expanded(child: Text(_pieceLabel(part),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12,
                        fontWeight: FontWeight.bold))),
                ]),
              ),
            )),
            IconButton(
              tooltip: 'Return video to the editor',
              onPressed: () => setState(() {
                _floating = false;
                _floatingPosition = null;
              }),
              icon: const Icon(Icons.close, size: 20),
            ),
          ]),
          ColoredBox(
            color: Colors.black,
            child: SizedBox(
              width: width,
              height: 140,
              child: video != null && video.value.isInitialized
                  ? Center(child: AspectRatio(
                      aspectRatio: video.value.aspectRatio,
                      child: VideoPlayer(video),
                    ))
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
          Row(children: [
            IconButton(
              tooltip: 'Play or pause floating preview',
              onPressed: video == null || _busy ? null :
                  () => unawaited(_togglePreviewPlayback()),
              icon: Icon(video?.value.isPlaying == true
                  ? Icons.pause : Icons.play_arrow),
            ),
            Expanded(child: Text(
              '${_clock(position.round())} / ${_clock(part.end)}',
              maxLines: 1, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12))),
            const SizedBox(width: 12),
          ]),
          Slider(
            value: position,
            min: part.start.toDouble(),
            max: part.end.toDouble(),
            onChanged: _busy ? null : (value) => unawaited(_seek(value)),
          ),
        ]),
      ),
    );
  }

  Widget _pieceRow(_Piece piece) => Card(
    child: Padding(padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_pieceLabel(piece),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        Text('${_clock(piece.start)}–${_clock(piece.end)} '
            '· ${_groups[piece.group] ?? "Recording"}',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        Text(p.basename(piece.path), maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
        Wrap(spacing: 6, children: [
          TextButton.icon(
            onPressed: _busy ? null : () => unawaited(_openFloating(piece)),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Preview'),
          ),
          DropdownButton<int>(
            value: piece.group,
            items: [for (final item in _groups.entries)
              DropdownMenuItem(value: item.key, child: Text(item.value))],
            onChanged: _busy ? null : (value) {
              if (value != null) _change(() => piece.group = value);
            },
          ),
          IconButton(
            tooltip: 'Move earlier',
            onPressed: _busy ? null : () => _reorder(piece, -1),
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            tooltip: 'Move later',
            onPressed: _busy ? null : () => _reorder(piece, 1),
            icon: const Icon(Icons.arrow_downward),
          ),
          FilterChip(
            label: const Text('Exclude damaged section'),
            selected: piece.excluded,
            onSelected: _busy ? null :
                (value) => _change(() => piece.excluded = value),
          ),
        ]),
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Reconstruct Recordings')),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : SafeArea(child: LayoutBuilder(
            builder: (context, bounds) => Stack(children: [
              ListView(padding: const EdgeInsets.all(12),
                children: [
              const Text('Find the scramble, split at its edges, exclude '
                  'the damaged piece, then assign and reorder the surviving '
                  'pieces. Original segments are never modified.'),
              const Text('Tap Preview or Play to float the video over '
                  'the lists. Drag its title bar to move it.'),
              if (widget.segmentPaths.map(_segmentRun).toSet().length > 1)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Multiple recovery attempts are open together. '
                      'Assign pieces from any attempt to the same recording '
                      'and change their order before exporting.'),
                ),
              _segmentNavigator(),
              const SizedBox(height: 12),
              _preview(),
              if (_busy) const LinearProgressIndicator(),
              if (_notice != null) Text(_notice!),
              if (_error != null) Text(_error!,
                  style: const TextStyle(color: Colors.orangeAccent)),
              const Divider(),
              Text('Pieces: ${_segmentFilter == null ? _pieces.length : _pieces.where((x) => x.path == _segmentFilter).length} '
                  'of ${_pieces.length}',
                  style: Theme.of(context).textTheme.titleMedium),
              if (_segmentFilter != null)
                Text('Showing ${_segmentLabel(_segmentFilter!)} only. '
                    'Choose All segments to see every piece.'),
              for (final piece in _pieces)
                if (_segmentFilter == null || piece.path == _segmentFilter)
                  _pieceRow(piece),
              const Divider(),
              Row(children: [
                const Expanded(child: Text('Recordings',
                    style: TextStyle(fontWeight: FontWeight.bold))),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () {
                    final id = _groups.keys.reduce((a, b) => a > b ? a : b) + 1;
                    _change(() => _groups[id] = 'Recording $id');
                    unawaited(_rename(id));
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ]),
              for (final item in _groups.entries)
                ListTile(
                  title: Text(item.value),
                  subtitle: Text('${_pieces.where((x) => x.group == item.key && !x.excluded).length} selected pieces'),
                  leading: IconButton(
                    onPressed: _busy ? null :
                        () => unawaited(_rename(item.key)),
                    icon: const Icon(Icons.edit),
                  ),
                  trailing: FilledButton(
                    onPressed: _busy ? null :
                        () => unawaited(_export(item.key)),
                    child: const Text('Export'),
                  ),
                ),
              const Text('Accurate cuts require high-quality re-encoding. '
                  'Each recording is exported separately as MKV. '
                  'The original footage remains untouched.',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 24),
                ]),
              if (_floating) _floatingPreview(bounds),
            ]),
          )),
    ),
  );
}
