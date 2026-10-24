import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'recovery_destination.dart';
import 'raw_video_scan.dart';
import 'reconstruction_editor.dart';

enum _RecoveryView { all, segments, otherVideos, reports }
enum _SavedMenuAction { reconstruct, diagnostics, destination, select }
enum _FileAction { play, verify, inspect, export, readReport, delete }

class SavedRecoveriesScreen extends StatefulWidget {
  const SavedRecoveriesScreen({super.key});
  @override
  State<SavedRecoveriesScreen> createState() => _SavedRecoveriesScreenState();
}

class _SavedRecoveriesScreenState extends State<SavedRecoveriesScreen> {
  List<FileStat> stats = [];
  List<String> paths = [];
  bool loading = true;
  bool busy = false;
  String? message;
  _RecoveryView _view = _RecoveryView.all;
  bool _selecting = false;
  final Set<String> _selectedPaths = {};
  List<Map<String, dynamic>> exits = [];
  String? exitError;
  String? lastFatalException;

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    unawaited(loadExits());
  }

  String size(int bytes) => bytes >= 1073741824
      ? '${(bytes / 1073741824).toStringAsFixed(2)} GB'
      : '${(bytes / 1048576).toStringAsFixed(1)} MB';

  Future<void> refresh({bool keepMessage = false}) async {
    if (busy) { return; }
    setState(() { loading = true; if (!keepMessage) message = null; });
    try {
      final dir = Directory(p.join(
          (await getApplicationDocumentsDirectory()).path,
          'DroidVidRecoveries'));
      final found = <String>[];
      final info = <FileStat>[];
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) { continue; }
          found.add(entity.path);
          info.add(await entity.stat());
        }
      }
      final indices = List<int>.generate(found.length, (i) => i);
      indices.sort((a, b) => info[b].size.compareTo(info[a].size));
      if (mounted) { setState(() {
        paths = [for (final i in indices) found[i]];
        stats = [for (final i in indices) info[i]];
      }); }
    } catch (e) {
      if (mounted) setState(() => message = 'Cannot list recoveries: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }


  bool isSegment(String path) =>
      RegExp(r'\.segment_\d+\.mkv$').hasMatch(p.basename(path));

  bool isVideoFile(String path) => const {
    '.mp4', '.mkv', '.mov', '.mpg', '.mpeg', '.avi',
    '.wmv', '.m4v', '.webm', '.ts', '.m2ts',
  }.contains(p.extension(path).toLowerCase());

  String segmentRun(String path) =>
      path.replaceFirst(RegExp(r'\.segment_\d+\.mkv$'), '');

  int segmentOrdinal(String path) =>
      int.tryParse(RegExp(r'\.segment_(\d+)\.mkv$')
          .firstMatch(p.basename(path))?.group(1) ?? '') ?? -1;

  int runTimestamp(String stem) =>
      int.tryParse(p.basename(stem).split('_').last) ?? 0;

  String runDate(String stem) {
    final timestamp = runTimestamp(stem);
    if (timestamp < 1000000000000) return 'Unknown start time';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final hour = date.hour > 12 ? date.hour - 12 :
        (date.hour == 0 ? 12 : date.hour);
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.month}/${date.day}/${date.year} '
        '$hour:$minute ${date.hour >= 12 ? "PM" : "AM"}';
  }

  Future<void> loadExits() async {
    try {
      const channel = MethodChannel('droid_vid_player/diagnostics');
      final result = await channel.invokeListMethod<dynamic>(
          'recentProcessExits');
      final fatal = await channel.invokeMethod<String>('lastFatalException');
      if (!mounted) { return; }
      setState(() {
        exits = (result ?? const []).whereType<Map>().map((value) =>
            Map<String, dynamic>.from(value)).toList();
        exitError = null;
        lastFatalException = fatal;
      });
    } catch (e) {
      if (mounted) {
        setState(() => exitError = 'Exit history unavailable: $e');
      }
    }
  }

  String exitLabel(int reason) {
    switch (reason) {
      case 3: return 'Low memory';
      case 4: return 'App crash';
      case 5: return 'Native crash (possible FFmpeg or codec)';
      case 6: return 'App not responding';
      default: return 'Android exit reason $reason';
    }
  }

  Future<void> readCheckpoint(String path) async {
    try {
      final file = File(path);
      final length = await file.length();
      final stream = file.openRead(0, length > 16384 ? 16384 : length);
      final chunks = await stream.toList();
      final contents = utf8.decode(chunks.expand((c) => c).toList(),
          allowMalformed: true);
      if (mounted) {
        setState(() => message = 'Saved checkpoint: ${p.basename(path)}\n\n$contents');
      }
    } catch (e) {
      if (mounted) {
        setState(() => message = 'Checkpoint read failed: $e');
      }
    }
  }

  Future<void> verify(String path) async {
    if (busy) return;
    setState(() { busy = true; message = 'Checking the first five video frames…'; });
    try {
      final completed = Completer<void>();
      final session = await FFmpegKit.executeWithArgumentsAsync([
        '-hide_banner', '-nostdin', '-loglevel', 'error',
        '-threads', '2', '-i', path,
        '-map', '0:v:0', '-an', '-frames:v', '5',
        '-f', 'null', '-',
      ], (session) {
        if (!completed.isCompleted) completed.complete();
      });
      await completed.future.timeout(const Duration(seconds: 45));
      final code = await session.getReturnCode();
      if (mounted) {
        setState(() => message = ReturnCode.isSuccess(code)
          ? 'Initial video decoding succeeded. Full playback is unverified.'
          : 'Initial decoding failed. Do not delete this file yet.');
      }
    } catch (e) {
      if (mounted) setState(() => message = 'Verification error: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> inspectBytes(String path) async {
    if (busy) { return; }
    setState(() {
      busy = true;
      message = 'Scanning internal byte markers without creating a copy…';
    });
    try {
      final scan = await scanRawVideo(path);
      if (mounted) {
        setState(() => message = '${scan.diagnostic}\n'
            'Markers are not evidence of decodable frames. '
            'An unfinished MP4 may lack the movie index.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => message = 'Byte inspection failed: $e');
      }
    } finally {
      if (mounted) { setState(() => busy = false); }
    }
  }

  String sourceGroup(String filename) {
    final source = filename.split(RegExp(
        r'_(?:deep_high_quality|quick_repair|guided)_')).first;
    return source;
  }

  Future<void> export(String path) async {
    if (busy) return;
    final length = await File(path).length();
    if (!mounted) { return; }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export a copy?'),
        content: Text('This file is ${size(length)}. Exporting may '
            'need that much additional free storage. The private original '
            'will not be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Export')),
        ],
      ),
    );
    if (ok != true || !mounted) { return; }
    setState(() { busy = true; message = 'Exporting file…'; });
    try {
      final uri = await RecoveryDestination.selectedUri();
      if (uri == null || uri.isEmpty) {
        if (mounted) setState(() => message = 'Choose a destination folder first.');
        return;
      }
      await RecoveryDestination.exportToChosenFolder(path);
      if (mounted) {
        setState(() => message =
            'Export finished. The private original was preserved.');
      }
    } catch (e) {
      if (mounted) setState(() => message = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }


  /// Segment files referenced by saved reconstruction edit decisions.
  Future<Set<String>> _projectReferences() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'DroidVidRecoveryProjects'));
    if (!await dir.exists()) return <String>{};
    final referenced = <String>{};
    await for (final item in dir.list(followLinks: false)) {
      if (item is! File || !item.path.endsWith('.reconstruction.json')) {
        continue;
      }
      try {
        final json = jsonDecode(await item.readAsString());
        if (json is! Map || json['pieces'] is! List) {
          throw const FormatException('Missing reconstruction pieces');
        }
        for (final part in json['pieces'] as List) {
          if (part is Map && part['path'] is String) {
            referenced.add(p.normalize(part['path'] as String));
          }
        }
      } catch (error) {
        throw StateError('Cannot check reconstruction project '
            '${p.basename(item.path)}: $error. '
            'Deletion was stopped to protect recovered footage.');
      }
    }
    return referenced;
  }

  Future<void> _deleteFiles(List<String> requested) async {
    if (busy || requested.isEmpty) return;
    final allowed = paths.toSet();
    final files = requested.where(allowed.contains).toSet().toList();
    if (files.isEmpty) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final directory = p.normalize(p.join(docs.path, 'DroidVidRecoveries'));
      final references = await _projectReferences();
      var bytes = 0;
      var linked = 0;
      final verified = <String>[];
      for (final path in files) {
        final normalized = p.normalize(path);
        if (p.dirname(normalized) != directory) {
          throw StateError('Deletion is restricted to the saved recovery folder.');
        }
        final file = File(normalized);
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) {
          throw StateError('Unable to delete a non-regular file: '
              '${p.basename(normalized)}');
        }
        verified.add(normalized);
        bytes += stat.size;
        if (references.contains(normalized)) linked++;
      }
      if (!mounted) return;
      var acknowledgeLinks = false;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (ctx, redraw) => AlertDialog(
            title: Text('Delete ${verified.length} saved '
                '${verified.length == 1 ? "file" : "files"}?'),
            content: SingleChildScrollView(child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Space to free: ${size(bytes)}.'),
                const SizedBox(height: 8),
                const Text('These files will be permanently removed from '
                    'the app. This cannot be undone. It will not delete '
                    'the original source video or exported folder copies.'),
                const SizedBox(height: 8),
                for (final path in verified.take(4))
                  Text('• ${p.basename(path)}',
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                if (verified.length > 4)
                  Text('…and ${verified.length - 4} more files'),
                if (linked > 0) ...[
                  const SizedBox(height: 12),
                  Text('Warning: $linked selected '
                      '${linked == 1 ? "file is" : "files are"} used by '
                      'saved reconstruction projects. Those edits may no '
                      'longer play or export after deletion.'),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('I understand that linked '
                        'reconstructions may break'),
                    value: acknowledgeLinks,
                    onChanged: (value) =>
                        redraw(() => acknowledgeLinks = value ?? false),
                  ),
                ],
              ],
            )),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: linked > 0 && !acknowledgeLinks ? null :
                    () => Navigator.pop(dialog, true),
                child: Text('Permanently delete ${verified.length}'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() {
        busy = true;
        message = 'Deleting only the selected saved files…';
      });
      var deleted = 0;
      var freed = 0;
      final failures = <String>[];
      for (final path in verified) {
        try {
          final local = File(path);
          final length = await local.length();
          await local.delete();
          deleted++;
          freed += length;
        } catch (error) {
          failures.add('${p.basename(path)}: $error');
        }
      }
      if (mounted) {
        setState(() {
          _selectedPaths.removeAll(verified);
          _selecting = false;
          message = 'Deleted $deleted of ${verified.length} files '
              '(${size(freed)}).'
              '${failures.isEmpty ? "" : " Some deletions failed: ${failures.take(3).join("; ")}"}';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => message = 'Deletion cancelled: $error');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await refresh(keepMessage: true);
      }
    }
  }

  void _toggleSelection(String path) {
    setState(() {
      if (!_selectedPaths.add(path)) _selectedPaths.remove(path);
    });
  }


  void _setView(_RecoveryView next) {
    setState(() {
      _view = next;
      _selectedPaths.clear();
    });
  }

  Future<void> _reconstructRecordings() async {
    final segments = paths.where(isSegment).toList()..sort();
    final runs = segments.map(segmentRun).toSet().toList()
      ..sort((a, b) => runTimestamp(b).compareTo(runTimestamp(a)));
    if (!mounted || runs.isEmpty) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose recovery attempt'),
        content: SizedBox(
          width: double.maxFinite,
          height: (runs.length * 70.0).clamp(80.0, 370.0),
          child: ListView.builder(
            itemCount: runs.length,
            itemBuilder: (_, index) {
              final stem = runs[index];
              final count = segments.where((x) => segmentRun(x) == stem).length;
              return ListTile(
                title: Text('Attempt ${runs.length - index}'),
                subtitle: Text('${runDate(stem)} · $count segments'),
                onTap: () => Navigator.pop(ctx, stem),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
        ],
      ),
    );
    if (!mounted || chosen == null) return;
    await Navigator.push<void>(context, MaterialPageRoute<void>(
      builder: (_) => ReconstructionEditor(segmentPaths: segments
          .where((x) => segmentRun(x) == chosen).toList()),
    ));
    if (mounted) unawaited(refresh());
  }

  Future<void> _showDiagnostics() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.72,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              const Expanded(child: Text('Recovery diagnostics',
                  style: TextStyle(fontSize: 19,
                      fontWeight: FontWeight.bold))),
              IconButton(
                tooltip: 'Refresh exit history',
                icon: const Icon(Icons.refresh),
                onPressed: () async {
                  await loadExits();
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) unawaited(_showDiagnostics());
                },
              ),
            ]),
            if (exitError != null) SelectableText(exitError!),
            if (lastFatalException != null &&
                lastFatalException!.isNotEmpty)
              ExpansionTile(
                title: const Text('Last fatal exception'),
                children: [SelectableText(lastFatalException!)],
              ),
            if (exits.isEmpty && exitError == null)
              const Text('No recent Android process exits were returned.'),
            for (final item in exits)
              ListTile(
                title: Text(exitLabel(
                    (item['reason'] as num?)?.toInt() ?? -1)),
                subtitle: SelectableText(
                    '${DateTime.fromMillisecondsSinceEpoch((item['timestamp'] as num?)?.toInt() ?? 0).toLocal()}\n'
                    '${item['description'] ?? ''}'),
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> _showDestination() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        child: SingleChildScrollView(child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Export destination',
                style: TextStyle(fontSize: 20,
                    fontWeight: FontWeight.bold)),
            RecoveryDestinationPicker(disabled: busy),
          ],
        )),
      )),
    );
  }

  void _fileAction(_FileAction action, String path) {
    if (busy) return;
    switch (action) {
      case _FileAction.play:
        Navigator.of(context).pop(path);
      case _FileAction.verify:
        unawaited(verify(path));
      case _FileAction.inspect:
        unawaited(inspectBytes(path));
      case _FileAction.export:
        unawaited(export(path));
      case _FileAction.readReport:
        unawaited(readCheckpoint(path));
      case _FileAction.delete:
        unawaited(_deleteFiles([path]));
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = stats.fold<int>(0, (sum, stat) => sum + stat.size);
    final segmentCount = paths.where(isSegment).length;
    final otherVideos = paths.where((x) =>
        isVideoFile(x) && !isSegment(x)).length;
    final reports = paths.length - segmentCount - otherVideos;
    final runStems = paths.where(isSegment).map(segmentRun).toSet().toList()
      ..sort((a, b) {
        final byTime = runTimestamp(b).compareTo(runTimestamp(a));
        return byTime == 0 ? b.compareTo(a) : byTime;
      });
    final runNumbers = <String, int>{
      for (var i = 0; i < runStems.length; i++)
        runStems[i]: runStems.length - i,
    };
    final runCounts = <String, int>{
      for (final stem in runStems)
        stem: paths.where((x) => isSegment(x) &&
            segmentRun(x) == stem).length,
    };
    final visible = List<int>.generate(paths.length, (index) => index)
        .where((i) {
          final path = paths[i];
          switch (_view) {
            case _RecoveryView.all: return true;
            case _RecoveryView.segments: return isSegment(path);
            case _RecoveryView.otherVideos:
              return isVideoFile(path) && !isSegment(path);
            case _RecoveryView.reports: return !isVideoFile(path);
          }
        }).toList();
    if (_view == _RecoveryView.segments) {
      visible.sort((a, b) {
        final groupA = runNumbers[segmentRun(paths[a])] ?? 0;
        final groupB = runNumbers[segmentRun(paths[b])] ?? 0;
        final compared = groupB.compareTo(groupA);
        return compared == 0
            ? segmentOrdinal(paths[a]).compareTo(segmentOrdinal(paths[b]))
            : compared;
      });
    } else {
      visible.sort((a, b) => stats[b].modified.compareTo(stats[a].modified));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Saved Recoveries'), actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: busy || loading ? null : refresh,
          icon: const Icon(Icons.refresh),
        ),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Files: ${paths.length} · Total: ${size(total)}'),
            const Text('Files are only deleted when you choose Delete and confirm. '
                'Partial videos may still contain recoverable footage.'),
            if (segmentCount > 0)
              FilledButton.icon(
                onPressed: busy ? null : () async {
                  final segments = paths.where(isSegment).toList()..sort();
                  final groups = runStems;
                  if (!mounted) return;
                  final chosen = await showDialog<String>(
                    context: context,
                    builder: (ctx) => SimpleDialog(
                      title: const Text('Select recovery run'),
                      children: [
                        for (final stem in groups)
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(ctx, stem),
                            child: Text('Attempt ${runNumbers[stem]} · '
                                '${runDate(stem)} · '
                                '${runCounts[stem]} segments'),
                          ),
                      ],
                    ),
                  );
                  if (!context.mounted || chosen == null) return;
                  await Navigator.push<void>(context,
                    MaterialPageRoute<void>(builder: (_) =>
                      ReconstructionEditor(segmentPaths: segments
                          .where((x) => x.startsWith('$chosen.segment_')).toList())));
                  if (mounted) unawaited(refresh());
                },
                icon: const Icon(Icons.movie_edit),
                label: const Text('Reconstruct Recordings'),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 4, children: [
              ChoiceChip(
                label: Text('All (${paths.length})'),
                selected: _view == _RecoveryView.all,
                onSelected: (_) => setState(() { _view = _RecoveryView.all; _selectedPaths.clear(); }),
              ),
              ChoiceChip(
                label: Text('Segments ($segmentCount)'),
                selected: _view == _RecoveryView.segments,
                onSelected: (_) => setState(() { _view = _RecoveryView.segments; _selectedPaths.clear(); }),
              ),
              ChoiceChip(
                label: Text('Other videos ($otherVideos)'),
                selected: _view == _RecoveryView.otherVideos,
                onSelected: (_) => setState(() { _view = _RecoveryView.otherVideos; _selectedPaths.clear(); }),
              ),
              ChoiceChip(
                label: Text('Logs & reports ($reports)'),
                selected: _view == _RecoveryView.reports,
                onSelected: (_) => setState(() { _view = _RecoveryView.reports; _selectedPaths.clear(); }),
              ),
            ]),
            Text('Showing ${visible.length} of ${paths.length} saved files',
                style: Theme.of(context).textTheme.bodySmall),
            Row(children: [
              TextButton.icon(
                onPressed: busy || loading ? null : () => setState(() {
                  _selecting = !_selecting;
                  if (!_selecting) _selectedPaths.clear();
                }),
                icon: Icon(_selecting ? Icons.close : Icons.checklist),
                label: Text(_selecting ? 'Done selecting' : 'Select files'),
              ),
              if (_selecting)
                TextButton(
                  onPressed: busy || loading ? null : () => setState(() {
                    _selectedPaths.addAll(visible.map((i) => paths[i]));
                  }),
                  child: const Text('Select visible'),
                ),
            ]),
            if (_selecting)
              Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${_selectedPaths.length} selected'),
                  TextButton(
                    onPressed: busy ? null : () => setState(
                        () => _selectedPaths.clear()),
                    child: const Text('Clear'),
                  ),
                  FilledButton.icon(
                    onPressed: busy || _selectedPaths.isEmpty ? null :
                        () => unawaited(_deleteFiles(_selectedPaths.toList())),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete selected'),
                  ),
                ],
              ),
            if (exitError != null)
              Text(exitError!, style: const TextStyle(fontSize: 12)),
            if (lastFatalException != null &&
                lastFatalException!.isNotEmpty)
              ExpansionTile(
                title: const Text('Last fatal exception details'),
                subtitle: const Text('Crash trace captured on the device'),
                children: [
                  SizedBox(height: 250, child: SingleChildScrollView(
                    child: SelectableText(lastFatalException!),
                  )),
                ],
              ),
            if (exits.isNotEmpty)
              ExpansionTile(
                title: const Text('Recent Android process exits'),
                subtitle: const Text('Check why the app closed'),
                children: [
                  SizedBox(height: 180, child: ListView(children: [
                    for (final item in exits.take(5))
                      ListTile(
                        dense: true,
                        title: Text(exitLabel(
                            (item['reason'] as num?)?.toInt() ?? -1)),
                        subtitle: Text(
                            '${DateTime.fromMillisecondsSinceEpoch((item['timestamp'] as num?)?.toInt() ?? 0).toLocal()}\n'
                            '${item['description'] ?? ''}',
                            maxLines: 4),
                      ),
                  ])),
                ],
              ),
            ExpansionTile(
              title: const Text('Export destination'),
              subtitle: const Text('Tap to choose or change the folder'),
              children: [RecoveryDestinationPicker(disabled: busy)],
            ),
            if (busy) const LinearProgressIndicator(),
            if (message != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(child: SelectableText(message!)),
              ),
          ]),
        ),
        Expanded(child: loading
          ? const Center(child: CircularProgressIndicator())
          : visible.isEmpty
            ? const Center(child: Text(
                'No files found in the private recovery folder. '
                'Other app data may exist elsewhere.',
                textAlign: TextAlign.center))
            : ListView.builder(itemCount: visible.length, itemBuilder: (context, row) {
                final i = visible[row];
                final path = paths[i];
                final name = p.basename(path);
                final incomplete = name.contains('.partial.') ||
                    name.contains('.working.');
                final video = isVideoFile(path);
                final similar = paths.where((other) =>
                    sourceGroup(p.basename(other)) == sourceGroup(name)).length;
                final match = RegExp(r'\.segment_(\d+)\.mkv$')
                    .firstMatch(name);
                final segmentNumber = match == null ? null :
                    (int.tryParse(match.group(1) ?? '') ?? 0) + 1;
                final checkpoint = name.endsWith('.checkpoint.txt');
                final run = isSegment(path) ? segmentRun(path) : null;
                final attempt = run == null ? null : runNumbers[run];
                final isRunStart = run != null &&
                    (row == 0 ||
                        !isSegment(paths[visible[row - 1]]) ||
                        segmentRun(paths[visible[row - 1]]) != run);
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_view == _RecoveryView.segments && isRunStart)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
                        child: Text('Recovery attempt $attempt '
                            '· ${runDate(run)} '
                            '· ${runCounts[run]} segments',
                            style: const TextStyle(fontSize: 16,
                                fontWeight: FontWeight.bold)),
                      ),
                    Card(child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (segmentNumber != null)
                      Text('Attempt ${attempt ?? "?"} · '
                          'Segment $segmentNumber of ${runCounts[run] ?? "?"}',
                          style: const TextStyle(fontSize: 18,
                              fontWeight: FontWeight.bold)),
                    if (_selecting)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Select this file for deletion'),
                        value: _selectedPaths.contains(path),
                        onChanged: busy ? null :
                            (_) => _toggleSelection(path),
                      ),
                    Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text('${size(stats[i].size)}'
                        '${incomplete ? ' · Incomplete/working' : ' · Saved'}'
                        '${video ? '' : ' · Non-video'}'),
                    if (similar > 1)
                      Text('$similar saved files share this source name; '
                          'these are not confirmed duplicates.'),
                    Wrap(spacing: 6, children: [
                      if (checkpoint)
                        OutlinedButton(
                          onPressed: busy ? null : () => readCheckpoint(path),
                          child: const Text('View checkpoint'),
                        ),
                      OutlinedButton(
                        onPressed: busy || !video ? null : () => verify(path),
                        child: const Text('Verify sample'),
                      ),
                      OutlinedButton(
                        onPressed: busy || !video ? null :
                            () => inspectBytes(path),
                        child: const Text('Inspect bytes'),
                      ),
                      OutlinedButton(
                        onPressed: busy || !video ? null :
                            () => Navigator.of(context).pop(path),
                        child: const Text('Play'),
                      ),
                      FilledButton.tonal(
                        onPressed: busy || !video ? null : () => export(path),
                        child: const Text('Export'),
                      ),
                      if (!_selecting)
                        OutlinedButton.icon(
                          onPressed: busy ? null :
                              () => unawaited(_deleteFiles([path])),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete'),
                        ),
                    ]),
                  ]),
                )),
                  ],
                );
              })),
      ]),
    );
  }
}
