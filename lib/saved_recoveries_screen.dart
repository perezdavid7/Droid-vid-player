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
  bool _exporting = false;
  String? _exportTarget;
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
    int length;
    String destinationLabel;
    try {
      length = await File(path).length();
      destinationLabel = await RecoveryDestination.selectedLabel();
    } catch (error) {
      if (!mounted) return;
      setState(() => message = 'Unable to prepare export: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not prepare the video export.')),
      );
      return;
    }
    if (!mounted) return;
    final name = p.basename(path);
    final gallery = destinationLabel == 'Default: Gallery / Droid Vid Player';
    final destinationName = gallery
        ? 'Gallery / Droid Vid Player'
        : destinationLabel;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Export this video?'),
        content: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, maxLines: 3, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 10),
            Text('Size: ${size(length)}'),
            const SizedBox(height: 8),
            const Text('Save to:', style: TextStyle(
                fontWeight: FontWeight.bold)),
            Text(destinationName),
            const SizedBox(height: 8),
            const Text('Exporting creates a separate file and may take '
                'several minutes. The original recovered segment will '
                'remain in Droid Vid Player.'),
          ],
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Start export'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      busy = true;
      _exporting = true;
      _exportTarget = destinationName;
      message = 'Exporting $name to $destinationName… '
          'Keep the app open until confirmation appears.';
    });
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Export started: saving to $destinationName…'),
        duration: const Duration(seconds: 4)),
    );

    String? savedTo;
    String? failure;
    try {
      // Honor the configured default Gallery even when no SAF folder exists.
      savedTo = await RecoveryDestination.exportRecoveredVideo(path);
    } catch (error) {
      failure = '$error';
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          _exporting = false;
          _exportTarget = null;
          message = savedTo != null
              ? 'Export completed: $name\nSaved to: $savedTo. '
                'The original recovered segment was preserved.'
              : 'Export was not confirmed for $name: '
                '${failure ?? "Unknown error"}. '
                'The source segment is still saved in Droid Vid Player.';
        });
      }
    }
    if (!mounted) return;
    final confirmedDestination = savedTo;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (confirmedDestination != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Export complete · $confirmedDestination'),
        duration: const Duration(seconds: 7),
      ));
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Export complete'),
          content: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('The video was saved to:'),
              const SizedBox(height: 6),
              SelectableText(confirmedDestination,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text('File:'),
              SelectableText(name),
              if (gallery && p.extension(path).toLowerCase() == '.mkv') ...[
                const SizedBox(height: 12),
                const Text('Some Gallery apps do not display MKV videos. '
                    'If it is not visible, choose an export folder instead '
                    'and locate it through My Files.'),
              ],
              const SizedBox(height: 12),
              const Text('The original recovered segment was not deleted.'),
            ],
          )),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Export failed. Your recovered segment is still safe.'),
        duration: Duration(seconds: 7),
      ));
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Export did not finish'),
          content: SingleChildScrollView(
            child: Text('Destination: $destinationName\n\n'
                '${failure ?? "Unknown error"}\n\n'
                'The original segment remains available in Saved '
                'Recoveries. You can choose another destination using '
                'the three-dot Recovery tools menu, then retry.'),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('OK'),
            ),
          ],
        ),
      );
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
    final reportCount = paths.length - segmentCount - otherVideos;
    final runStems = paths.where(isSegment).map(segmentRun).toSet().toList()
      ..sort((a, b) => runTimestamp(b).compareTo(runTimestamp(a)));
    final runNumbers = <String, int>{
      for (var i = 0; i < runStems.length; i++)
        runStems[i]: runStems.length - i,
    };
    final visible = List<int>.generate(paths.length, (i) => i)
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
        final order = (runNumbers[segmentRun(paths[b])] ?? 0)
            .compareTo(runNumbers[segmentRun(paths[a])] ?? 0);
        return order != 0 ? order :
            segmentOrdinal(paths[a]).compareTo(segmentOrdinal(paths[b]));
      });
    } else {
      visible.sort((a, b) => stats[b].modified.compareTo(stats[a].modified));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved Recoveries'),
        actions: [
          IconButton(
            tooltip: 'Refresh files',
            onPressed: busy || loading ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<_SavedMenuAction>(
            tooltip: 'Recovery tools',
            onSelected: (action) {
              switch (action) {
                case _SavedMenuAction.reconstruct:
                  unawaited(_reconstructRecordings());
                case _SavedMenuAction.diagnostics:
                  unawaited(_showDiagnostics());
                case _SavedMenuAction.destination:
                  unawaited(_showDestination());
                case _SavedMenuAction.select:
                  setState(() {
                    _selecting = !_selecting;
                    if (!_selecting) _selectedPaths.clear();
                  });
              }
            },
            itemBuilder: (_) => [
              if (segmentCount > 0)
                const PopupMenuItem(
                  value: _SavedMenuAction.reconstruct,
                  child: Text('Reconstruct recordings'),
                ),
              const PopupMenuItem(
                value: _SavedMenuAction.diagnostics,
                child: Text('Crash diagnostics'),
              ),
              const PopupMenuItem(
                value: _SavedMenuAction.destination,
                child: Text('Export destination'),
              ),
              PopupMenuItem(
                value: _SavedMenuAction.select,
                child: Text(_selecting ? 'Done selecting' : 'Select files'),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: _exporting
          ? SafeArea(child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text('Exporting to ${_exportTarget ?? "selected destination"}…'),
                const Text('Please keep the app open until export completes.',
                    style: TextStyle(fontSize: 12)),
              ]),
            ))
          : null,
      // One unified scrolling viewport: headers, segment cards and controls
      // all travel together, rather than trapping files in a short list.
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${paths.length} files · ${size(total)}',
                    style: Theme.of(context).textTheme.bodyMedium),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    ChoiceChip(
                      label: Text('All (${paths.length})'),
                      selected: _view == _RecoveryView.all,
                      onSelected: (_) => _setView(_RecoveryView.all),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text('Segments ($segmentCount)'),
                      selected: _view == _RecoveryView.segments,
                      onSelected: (_) => _setView(_RecoveryView.segments),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text('Other videos ($otherVideos)'),
                      selected: _view == _RecoveryView.otherVideos,
                      onSelected: (_) => _setView(_RecoveryView.otherVideos),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text('Reports ($reportCount)'),
                      selected: _view == _RecoveryView.reports,
                      onSelected: (_) => _setView(_RecoveryView.reports),
                    ),
                  ]),
                ),
                if (busy) const LinearProgressIndicator(),
                if (message != null)
                  ExpansionTile(
                    initiallyExpanded: true,
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Last operation result'),
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: SingleChildScrollView(
                          child: SelectableText(message!),
                        ),
                      ),
                    ],
                  ),
                if (_selecting)
                  Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('${_selectedPaths.length} selected'),
                      TextButton(
                        onPressed: busy ? null : () => setState(() =>
                            _selectedPaths.addAll(visible.map((i) => paths[i]))),
                        child: const Text('Select shown'),
                      ),
                      TextButton(
                        onPressed: busy ? null : () => setState(
                            () => _selectedPaths.clear()),
                        child: const Text('Clear'),
                      ),
                      FilledButton.icon(
                        onPressed: busy || _selectedPaths.isEmpty ? null :
                            () => unawaited(_deleteFiles(_selectedPaths.toList())),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete'),
                      ),
                    ],
                  ),
              ],
            ),
          )),
          if (loading)
            const SliverFillRemaining(child: Center(
              child: CircularProgressIndicator(),
            ))
          else if (visible.isEmpty)
            const SliverFillRemaining(child: Center(
              child: Text('No files in this category.'),
            ))
          else SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (ctx, index) {
              final fileIndex = visible[index];
              final path = paths[fileIndex];
              final name = p.basename(path);
              final video = isVideoFile(path);
              final segment = isSegment(path);
              final run = segment ? segmentRun(path) : null;
              final number = segmentOrdinal(path) + 1;
              final runNumber = run == null ? null : runNumbers[run];
              final header = segment && _view == _RecoveryView.segments &&
                  (index == 0 ||
                    segmentRun(paths[visible[index - 1]]) != run);
              final fileIsCheckpoint = name.endsWith('.checkpoint.txt');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (header)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
                      child: Text('Attempt $runNumber · ${runDate(run!)}',
                        style: Theme.of(context).textTheme.titleSmall),
                    ),
                  Card(
                    margin: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                      child: Row(children: [
                        if (_selecting)
                          Checkbox(
                            value: _selectedPaths.contains(path),
                            onChanged: busy ? null :
                                (_) => _toggleSelection(path),
                          ),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(segment
                                ? 'Attempt $runNumber · Segment $number'
                                : name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text('${size(stats[fileIndex].size)}'
                                ' · ${segment ? "Recovered segment" :
                                  video ? "Video" : "Report"}',
                                style: Theme.of(context).textTheme.bodySmall),
                            if (segment)
                              Text(name,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall),
                          ],
                        )),
                        if (video && !_selecting)
                          IconButton(
                            tooltip: 'Play video',
                            onPressed: busy ? null : () =>
                                Navigator.of(context).pop(path),
                            icon: const Icon(Icons.play_arrow),
                          ),
                        PopupMenuButton<_FileAction>(
                          tooltip: 'File actions',
                          enabled: !busy,
                          onSelected: (action) => _fileAction(action, path),
                          itemBuilder: (_) => [
                            if (video)
                              const PopupMenuItem(
                                value: _FileAction.play, child: Text('Play')),
                            if (video)
                              const PopupMenuItem(
                                value: _FileAction.verify,
                                child: Text('Verify sample')),
                            if (video)
                              const PopupMenuItem(
                                value: _FileAction.inspect,
                                child: Text('Inspect bytes')),
                            if (video)
                              const PopupMenuItem(
                                value: _FileAction.export,
                                child: Text('Export')),
                            if (fileIsCheckpoint)
                              const PopupMenuItem(
                                value: _FileAction.readReport,
                                child: Text('View checkpoint')),
                            const PopupMenuItem(
                              value: _FileAction.delete,
                              child: Text('Delete…')),
                          ],
                        ),
                      ]),
                    ),
                  ),
                ],
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 56)),
        ],
      ),
    );
  }
}
