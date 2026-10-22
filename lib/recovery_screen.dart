import 'dart:async';
import 'dart:io';
import 'raw_video_scan.dart';
import 'file_identification.dart';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/material.dart';
import 'recovery_destination.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

enum RecoveryMode { quickRepair, deepHighQuality, advancedAnalysis }

/// Experimental forward-only repair or decode -> re-encode recovery. Never seeks, records
/// only decoded media streams (not player UI), and never touches the original.
/// Recovery runs inside the foreground app; Android may suspend/kill it if the
/// app is backgrounded, so the screen is kept awake during processing.
class RecoveryScreen extends StatefulWidget {
  final String sourcePath;
  const RecoveryScreen({super.key, required this.sourcePath});

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  RecoveryMode _mode = RecoveryMode.deepHighQuality;
  RawVideoScan? _scan;
  FileIdentification? _identification;
  double _scanProgress = 0;
  bool _cancelScan = false;
  bool _running = false;
  bool _cancelling = false;
  bool _savingGallery = false;
  bool _gallerySaved = false;
  String? _exportLabel;
  String _status = 'Ready to begin recovery';
  String? _resultPath;
  String? _logPath;
  String? _partialPath;
  String? _error;
  int? _sessionId;
  int _generation = 0;
  int _frames = 0;
  String? _diagnostic;
  Duration _processed = Duration.zero;

  String get _name => p.basename(widget.sourcePath);
  String _duration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  Future<void> _wake(bool active) async {
    try {
      if (active) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {
      // Video recovery still works on platforms without wakelock support.
    }
  }

  Future<void> _analyzeRaw() async {
    if (_running || _savingGallery) return;
    final generation = ++_generation;
    setState(() {
      _running = true;
      _cancelling = false;
      _cancelScan = false;
      _scan = null;
      _identification = null;
      _scanProgress = 0;
      _error = null;
      _diagnostic = null;
      _status = 'Analyzing video structure…';
    });
    try {
      await _wake(true);
      final identification = await identifyFile(widget.sourcePath,
        isCancelled: () => _cancelScan || generation != _generation);
      if (!mounted || generation != _generation || _cancelScan) return;
      final scan = await scanRawVideo(widget.sourcePath,
        isCancelled: () => _cancelScan || generation != _generation,
        onProgress: (fraction) {
          // Prevent expensive rebuilds on every file chunk.
          if (!mounted || generation != _generation) return;
          if (fraction - _scanProgress >= 0.02 || fraction >= 1) {
            setState(() => _scanProgress = fraction);
          }
        },
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _scan = scan;
        _identification = identification;
        _diagnostic = '${identification.format}\n'
            'Signature: ${identification.evidence}\n'
            'MP4 top-level boxes: ${identification.mp4Boxes}\n'
            'MP4 structure truncated/invalid: ${identification.mp4Truncated}\n'
            'Sample: ${identification.sampledBytes} bytes, '
            'entropy ${identification.entropy.toStringAsFixed(2)}/8\n'
            'Pattern: ${identification.pattern}\n\n'
            '${scan.diagnostic}';
        _status = 'File analysis completed.';
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _status = _cancelScan ? 'Analysis cancelled.' : 'Analysis failed.';
        if (!_cancelScan) _error = '$e';
      });
    } finally {
      await _wake(false);
      if (mounted && generation == _generation) {
        setState(() {
          _running = false;
          _cancelling = false;
        });
      }
    }
  }

  Future<void> _start() async {
    if (_running || _savingGallery) return;
    if (_mode == RecoveryMode.advancedAnalysis) {
      await _analyzeRaw();
      return;
    }
    if (!await File(widget.sourcePath).exists()) {
      setState(() => _error = 'The selected file is no longer accessible. '
          'Reopen it with the file picker before retrying.');
      return;
    }
    final generation = ++_generation;
    setState(() {
      _running = true;
      _cancelling = false;
      _gallerySaved = false;
      _resultPath = null;
      _partialPath = null;
      _logPath = null;
      _error = null;
      _sessionId = null;
      _frames = 0;
      _diagnostic = null;
      _processed = Duration.zero;
      _status = _mode == RecoveryMode.quickRepair
          ? 'Quick Repair: rebuilding the container without re-encoding…'
          : 'Deep Recovery: decoding and rebuilding at high quality…';
    });
    try {
      final documents = await getApplicationDocumentsDirectory();
      final directory = Directory(p.join(documents.path, 'DroidVidRecoveries'));
      await directory.create(recursive: true);
      final cleanBase = p.basenameWithoutExtension(widget.sourcePath)
          .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final baseName = cleanBase.isEmpty ? 'video' :
          (cleanBase.length > 48 ? cleanBase.substring(0, 48) : cleanBase);
      final suffix = _mode == RecoveryMode.quickRepair
          ? 'quick_repair' : 'deep_high_quality';
      final stem = '${baseName}_${suffix}_${DateTime.now().millisecondsSinceEpoch}';
      final finalPath = p.join(directory.path, '$stem.mp4');
      final partialPath = p.join(directory.path, '$stem.partial.mp4');
      final logPath = p.join(directory.path, '$stem.log.txt');
      if (await File(finalPath).exists() || await File(partialPath).exists()) {
        throw StateError('A recovery output with this name already exists.');
      }
      _partialPath = partialPath;
      _logPath = logPath;
      await _wake(true);

      // Both modes run forward with no seeks.
      // Quick Repair copies compressed streams unchanged, so it cannot introduce
      // new generation loss. This does not necessarily fix all bad timestamps,
      // and codecs not permitted in MP4 will make it fail.
      // Deep Recovery re-encodes decoded streams using a higher-quality MPEG-4
      // setting (q:v=2 rather than the previous q:v=5). This can still lose
      // quality, and it cannot reconstruct missing/damaged frames.
      final sharedArgs = <String>[
        '-hide_banner', '-nostdin', '-loglevel', 'warning',
        '-fflags', '+genpts+discardcorrupt',
        '-err_detect', 'ignore_err',
        '-i', widget.sourcePath,
        '-map', '0:v:0', '-map', '0:a:0?',
        '-sn', '-dn',
      ];
      // MPEG program streams can contain resolution changes, damaged GOPs,
      // and wildly discontinuous PTS. Rebuild a stable 30 fps timeline from
      // successfully decoded frames and maintain one output frame size.
      // This path is deliberately limited to older MPEG inputs so other
      // videos retain their original resolutions and frame rates.
      final legacyMpeg = <String>{'.mpg', '.mpeg', '.m2v', '.vob'}
          .contains(p.extension(widget.sourcePath).toLowerCase());
      final encodingArgs = _mode == RecoveryMode.quickRepair
          ? <String>['-c', 'copy']
          : <String>[
              if (legacyMpeg) ...[
                '-vf',
                'scale=720:480:force_original_aspect_ratio=decrease,'
                'pad=720:480:(ow-iw)/2:(oh-ih)/2,setsar=1,'
                'setpts=N/(30*TB)',
                '-r', '30',
                '-fps_mode', 'cfr',
              ] else ...['-fps_mode', 'vfr'],
              '-c:v', 'mpeg4', '-q:v', '2',
              '-pix_fmt', 'yuv420p',
              '-c:a', 'aac', '-b:a', '192k',
              '-af', 'aresample=async=1000:first_pts=0',
            ];
      final args = <String>[
        ...sharedArgs,
        ...encodingArgs,
        '-avoid_negative_ts', 'make_zero',
        '-max_muxing_queue_size', '1024',
        '-movflags', '+faststart',
        '-f', 'mp4', '-n', partialPath,
      ];
      final session = await FFmpegKit.executeWithArgumentsAsync(
        args,
        (finished) {
          unawaited(_finish(finished, finalPath, partialPath, logPath, generation));
        },
        null,
        (statistics) {
          if (!mounted || generation != _generation) return;
          setState(() {
            _processed = Duration(milliseconds: statistics.getTime().clamp(0, 1 << 53).toInt());
            _frames = statistics.getVideoFrameNumber();
          });
        },
      );
      if (!mounted || generation != _generation) return;
      _sessionId = session.getSessionId();
      if (_cancelling && _sessionId != null) {
        await FFmpegKit.cancel(_sessionId);
      }
    } catch (e) {
      await _wake(false);
      if (!mounted || generation != _generation) return;
      setState(() {
        _running = false;
        _error = 'Could not start recovery: $e';
        _status = 'Recovery failed to start';
      });
    }
  }

  Future<void> _finish(
    FFmpegSession session,
    String finalPath,
    String partialPath,
    String logPath,
    int generation,
  ) async {
    try {
      final code = await session.getReturnCode();
      final logs = await session.getLogsAsString();
      final diagnostic = logs.length > 1400
          ? logs.substring(logs.length - 1400)
          : logs;
      await File(logPath).writeAsString(
        'Droid Vid Player sequential recovery (experimental)\n'
        'Mode: ${_mode == RecoveryMode.quickRepair ? 'Quick Repair' : 'Deep High Quality'}\n'
        'Source: ${widget.sourcePath}\n'
        'Output: $finalPath\n'
        'Exit code: ${code?.toString() ?? 'none'}\n'
        'Cancelled: $_cancelling\n'
        'Processed output time: ${_duration(_processed)}\n'
        'Decoded/encoded frames: $_frames\n\n'
        'FFmpeg log:\n$logs',
        flush: true,
      );
      final partial = File(partialPath);
      final hasPartial = await partial.exists() && await partial.length() > 4096;
      final success = ReturnCode.isSuccess(code) && hasPartial && !_cancelling;
      if (success) {
        await partial.rename(finalPath);
      }
      await _wake(false);
      if (!mounted || generation != _generation) return;
      setState(() {
        _running = false;
        _logPath = logPath;
        _partialPath = hasPartial && !success ? partialPath : null;
        _resultPath = success ? finalPath : null;
        _sessionId = null;
        _status = success
            ? (_mode == RecoveryMode.quickRepair
                ? 'Quick Repair completed without recompressing video.'
                : 'High-quality Deep Recovery completed.')
            : _cancelling ? 'Recovery stopped.' : 'Recovery incomplete.';
        _diagnostic = success ? null : diagnostic;
        _error = success ? null : _mode == RecoveryMode.quickRepair
            ? 'Quick Repair could not copy these streams to MP4, or their '
              'metadata is damaged. Try Deep Recovery instead.'
            : 'The input may contain unsupported or unrecoverable data. '
              'Check the FFmpeg diagnostic below.';
      });
      if (success) await _saveToGallery();
    } catch (e) {
      await _wake(false);
      if (!mounted || generation != _generation) return;
      setState(() {
        _running = false;
        _sessionId = null;
        _error = 'Recovery ended, but the output could not be finalized: $e';
      });
    }
  }

  Future<void> _cancel() async {
    if (!_running || _cancelling) return;
    if (_mode == RecoveryMode.advancedAnalysis) {
      setState(() {
        _cancelScan = true;
        _cancelling = true;
        _status = 'Stopping analysis…';
      });
      return;
    }
    setState(() {
      _cancelling = true;
      _status = 'Stopping recovery; waiting for the encoder…';
    });
    final id = _sessionId;
    if (id != null) {
      try {
        await FFmpegKit.cancel(id);
      } catch (e) {
        if (mounted) setState(() => _error = 'Cancel request failed: $e');
      }
    }
  }

  Future<void> _saveToGallery() async {
    final output = _resultPath;
    if (output == null || _savingGallery) return;
    setState(() {
      _savingGallery = true;
      _gallerySaved = false;
      _error = null;
      _status = 'Exporting to selected recovery destination…';
    });
    try {
      final destination = await RecoveryDestination.exportRecoveredVideo(output);
      if (!mounted) return;
      setState(() {
        _gallerySaved = true;
        _exportLabel = destination;
        _status = 'Recovered video exported to $destination.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Recovery succeeded, but export failed: $e. '
          'The app-stored copy is still available. Select another folder '
          'and retry saving without repeating recovery.');
    } finally {
      if (mounted) setState(() => _savingGallery = false);
    }
  }

  @override
  void dispose() {
    // Avoid orphaning active recovery by disallowing route pop while running.
    // OS app termination can still stop the native encoder.
    if (!_running) unawaited(_wake(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = _running || _savingGallery;
    return PopScope(
      canPop: !locked,
      child: Scaffold(
        appBar: AppBar(title: const Text('Recover & Record')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const Text('Recover & Record',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Text('Source: $_name', maxLines: 2,
                overflow: TextOverflow.ellipsis),
              const SizedBox(height: 12),
              const Text(
                'Choose a repair method or analyze the file first. Analysis '
                'reads the file in small chunks, including for multi-GB files. '
                'The original is never modified.',
              ),
              const SizedBox(height: 12),
              DropdownButton<RecoveryMode>(
                isExpanded: true,
                value: _mode,
                onChanged: locked ? null : (value) {
                  if (value == null) return;
                  setState(() => _mode = value);
                },
                items: const [
                  DropdownMenuItem(
                    value: RecoveryMode.quickRepair,
                    child: Text('Quick Repair — original quality'),
                  ),
                  DropdownMenuItem(
                    value: RecoveryMode.deepHighQuality,
                    child: Text('Deep Recovery — high quality'),
                  ),
                  DropdownMenuItem(
                    value: RecoveryMode.advancedAnalysis,
                    child: Text('Advanced Analysis — unknown source'),
                  ),
                ],
              ),
              Text(
                _mode == RecoveryMode.quickRepair
                    ? 'Copies original compressed streams without re-encoding '
                      'when the container remains readable.'
                    : _mode == RecoveryMode.deepHighQuality
                        ? 'Decodes frames and audio into a new MP4. Requires '
                          'FFmpeg to recognize the input container.'
                        : 'Scans MP4 box markers and potential raw H.264/H.265 '
                          'headers without loading the full video in memory. '
                          'Analysis does not reconstruct a missing MP4 index, '
                          'and detected byte signatures do not guarantee '
                          'recoverable video.',
              ),
              const SizedBox(height: 12),
              RecoveryDestinationPicker(disabled: locked),
              const SizedBox(height: 14),
              const Text(
                'Keep Droid Vid Player open and the phone plugged in for '
                'long recoveries. This first version keeps the screen awake '
                'but does not yet support reliable background processing.',
                style: TextStyle(color: Colors.amberAccent)),
              const SizedBox(height: 18),
              Text(_status, style: const TextStyle(fontSize: 16)),
              if (_running) ...[
                const SizedBox(height: 12),
                _mode == RecoveryMode.advancedAnalysis
                    ? LinearProgressIndicator(value: _scanProgress)
                    : const LinearProgressIndicator(),
                const SizedBox(height: 8),
                if (_mode == RecoveryMode.advancedAnalysis)
                  Text('Analyzed: ${(_scanProgress * 100).toStringAsFixed(0)}%')
                else ...[
                  Text('Processed output time: ${_duration(_processed)}'
                       '  ·  Frames: $_frames'),
                  const Text('Progress is not a percentage because damaged '
                             'videos may report an incorrect duration.'),
                ],
              ],
              if (_mode == RecoveryMode.advancedAnalysis &&
                  _scan != null && !_running)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _identification?.isNonVideo == true
                        ? 'The header identifies non-video data; video repair '
                          'is not recommended.'
                        : _identification?.category == 'video' &&
                            _scan!.psVideoPackets > 0
                            ? 'Recognized MPEG program stream with video '
                              'packet markers. A missing MP4 header is '
                              'normal here. If playback timestamps are '
                              'unreliable, try Quick Repair first, then '
                              'Deep Recovery if needed.'
                        : _identification?.category == 'video'
                            ? 'Recognized video container. Raw H.264/H.265 '
                              'signatures are not required for playback. '
                              'Repair suitability depends on the codec '
                              'and the decoder result.'
                            : _identification?.isMp4Family == true &&
                                _identification!.hasMdat &&
                                !_identification!.hasMoov
                                ? 'MP4 media data found without its movie '
                                  'index. Neither ordinary repair method '
                                  'can reliably recreate absent metadata.'
                                : _scan!.rawFormat != null
                                    ? 'Potential raw H.264/H.265 headers '
                                      'found; decodability is not yet proven.'
                                    : 'Format and video content could not '
                                      'be established. No recovery outcome '
                                      'can be inferred from this scan.',
                    style: const TextStyle(color: Colors.amberAccent),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
              ],
              if (_diagnostic != null && _diagnostic!.isNotEmpty) ...[
                const SizedBox(height: 12),
                ExpansionTile(
                  title: const Text('Technical diagnostic'),
                  children: [
                    SelectableText(_diagnostic!,
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              if (!_running && _resultPath == null)
                FilledButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.auto_fix_high),
                  label: Text(_mode == RecoveryMode.quickRepair
                      ? 'Start Quick Repair'
                      : _mode == RecoveryMode.deepHighQuality
                          ? 'Start High-Quality Deep Recovery'
                          : 'Analyze File Structure'),
                ),
              if (_running)
                OutlinedButton.icon(
                  onPressed: _cancelling ? null : _cancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(_cancelling ? 'Stopping…' :
                      _mode == RecoveryMode.advancedAnalysis
                          ? 'Cancel analysis' : 'Stop recovery'),
                ),
              if (_resultPath != null) ...[
                const SizedBox(height: 12),
                SelectableText('App copy: ${p.basename(_resultPath!)}'),
                if (_savingGallery) const LinearProgressIndicator(),
                if (_gallerySaved)
                  Text('Saved to: ${_exportLabel ?? "Selected destination"}',
                    style: const TextStyle(color: Colors.greenAccent)),
                if (!_gallerySaved && !_savingGallery)
                  FilledButton.tonal(
                    onPressed: _saveToGallery,
                    child: const Text('Retry save to selected folder'),
                  ),
                FilledButton.icon(
                  onPressed: locked ? null :
                    () => Navigator.of(context).pop(_resultPath),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play recovered video'),
                ),
              ],
              if (_partialPath != null)
                const Text('Partial output was retained in private app '
                    'storage for investigation. It may not be playable.'),
              if (_logPath != null)
                const Text('A recovery log was saved in private app storage.'),
              const SizedBox(height: 14),
              const Text('Original file is never overwritten.',
                style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }
}
