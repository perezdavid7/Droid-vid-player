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
  bool segmentsOnly = false;
  List<Map<String, dynamic>> exits = [];
  String? exitError;

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    unawaited(loadExits());
  }

  String size(int bytes) => bytes >= 1073741824
      ? '${(bytes / 1073741824).toStringAsFixed(2)} GB'
      : '${(bytes / 1048576).toStringAsFixed(1)} MB';

  Future<void> refresh() async {
    if (busy) { return; }
    setState(() { loading = true; message = null; });
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

  Future<void> loadExits() async {
    try {
      const channel = MethodChannel('droid_vid_player/diagnostics');
      final result = await channel.invokeListMethod<dynamic>(
          'recentProcessExits');
      if (!mounted) { return; }
      setState(() {
        exits = (result ?? const []).whereType<Map>().map((value) =>
            Map<String, dynamic>.from(value)).toList();
        exitError = null;
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

  @override
  Widget build(BuildContext context) {
    final total = stats.fold<int>(0, (sum, stat) => sum + stat.size);
    final segmentCount = paths.where(isSegment).length;
    final visible = List<int>.generate(paths.length, (index) => index)
        .where((i) => !segmentsOnly || isSegment(paths[i])).toList();
    if (segmentsOnly) {
      visible.sort((a, b) => paths[a].compareTo(paths[b]));
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
            const Text('No files will be deleted. A partial video may '
                'still contain recoverable footage.'),
            Wrap(children: [
              FilterChip(
                label: Text('Segments only ($segmentCount)'),
                selected: segmentsOnly,
                onSelected: (value) =>
                    setState(() => segmentsOnly = value),
              ),
            ]),
            if (exitError != null)
              Text(exitError!, style: const TextStyle(fontSize: 12)),
            if (exits.isNotEmpty)
              ExpansionTile(
                title: const Text('Recent Android process exits'),
                subtitle: const Text('Check why the app closed'),
                children: [
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
                ],
              ),
            RecoveryDestinationPicker(disabled: busy),
            if (busy) const LinearProgressIndicator(),
            if (message != null) SelectableText(message!),
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
                final ext = p.extension(path).toLowerCase();
                final video = const {'.mp4', '.mkv', '.mov', '.mpg',
                    '.mpeg', '.avi'}.contains(ext);
                final similar = paths.where((other) =>
                    sourceGroup(p.basename(other)) == sourceGroup(name)).length;
                final match = RegExp(r'\.segment_(\d+)\.mkv$')
                    .firstMatch(name);
                final segmentNumber = match == null ? null :
                    (int.tryParse(match.group(1) ?? '') ?? 0) + 1;
                final checkpoint = name.endsWith('.checkpoint.txt');
                return Card(child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (segmentNumber != null)
                      Text('Segment $segmentNumber',
                          style: const TextStyle(fontSize: 18,
                              fontWeight: FontWeight.bold)),
                    Text(name, maxLines: 3, overflow: TextOverflow.ellipsis),
                    Text('${size(stats[i].size)}'
                        '${incomplete ? ' · Incomplete/working' : ' · Saved'}'
                        '${video ? '' : ' · Non-video'}'),
                    if (similar > 1)
                      Text('$similar attempts share this source name; '
                          'not confirmed byte-for-byte duplicates.'),
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
                        onPressed: busy ? null : () => export(path),
                        child: const Text('Export'),
                      ),
                    ]),
                  ]),
                ));
              })),
      ]),
    );
  }
}
