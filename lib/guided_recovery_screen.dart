
import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/material.dart';
import 'recovery_destination.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'file_identification.dart';
import 'raw_video_scan.dart';
import 'recovery_screen.dart';

/// Guided recovery: quick preflight, lossless remux, decoding check, optional
/// high-quality re-encode. The original is never modified or overwritten.
/// Full byte scanning is reserved for files that cannot be identified.
class GuidedRecoveryScreen extends StatefulWidget {
  final String sourcePath;
  const GuidedRecoveryScreen({super.key, required this.sourcePath});

  @override
  State<GuidedRecoveryScreen> createState() => _GuidedRecoveryScreenState();
}

enum _SeekCheck { passed, failed, inconclusive }

class _GuidedRecoveryScreenState extends State<GuidedRecoveryScreen> {
  FileIdentification? _identified;
  RawVideoScan? _scan;
  bool _running = false;
  bool _cancelled = false;
  bool _didDeepScan = false;
  bool _canAttempt = false;
  bool _gallerySaved = false;
  String? _exportLabel;
  String? _exportError;
  bool _seekVerified = false;
  bool _preferReliablePlayback = false;
  bool _lastWasLossless = false;
  String? _result;
  String? _error;
  String _status = 'Inspecting file header…';
  String _advice = 'Please wait.';
  String _diagnostics = '';
  double _progress = 0;
  int _frames = 0;
  int? _activeSession;
  final _attemptLogs = <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_inspect());
    });
  }

  Future<void> _wake(bool enabled) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  }

  Future<void> _inspect() async {
    if (_running) return;
    setState(() {
      _running = true;
      _cancelled = false;
      _status = 'Identifying file…';
      _error = null;
    });
    try {
      final identification = await identifyFile(widget.sourcePath,
          isCancelled: () => _cancelled || !mounted);
      if (!mounted || _cancelled) return;
      final recognized = identification.category == 'video' ||
          identification.category == 'mp4' ||
          identification.category == 'media';
      final missingMp4Index = identification.isMp4Family &&
          identification.hasMdat && !identification.hasMoov;
      setState(() {
        _identified = identification;
        _canAttempt = recognized && !missingMp4Index;
        // Timestamp-corrupt MPEG Program Streams can survive stream-copy
        // but still hang on seeking. Prefer rebuilding their decode timeline,
        // while allowing a lossless-first override.
        _preferReliablePlayback =
            identification.format.startsWith('MPEG program stream');
        _status = 'Initial analysis complete.';
        if (identification.isNonVideo) {
          _advice = 'The header belongs to a non-video file. '
              'No automatic video recovery will run.';
        } else if (missingMp4Index) {
          _advice = 'MP4 media data exists, but the movie index is missing. '
              'Ordinary remuxing cannot reconstruct it. '
              'Advanced reconstruction may require a matching reference file.';
        } else if (recognized) {
          _advice = identification.format.startsWith('MPEG program stream')
              ? 'MPEG Program Stream detected. These recordings may carry '
                'unreliable timestamps even after lossless remuxing. '
                'Reliable playback is recommended for files that freeze '
                'during seeking, but requires re-encoding.'
              : 'Recognized media. Try lossless remuxing first; if it fails '
                'verification, rebuild decoded video automatically.';
        } else {
          _advice = 'Unknown format. Inspect the file for recoverable '
              'media signatures before selecting a recovery method.';
        }
        _diagnostics = 'Detected: ${identification.format}\n'
            'Evidence: ${identification.evidence}\n'
            'Data pattern: ${identification.pattern}\n'
            'MP4 boxes: ${identification.mp4Boxes}';
      });
    } catch (e) {
      if (mounted && !_cancelled) {
        setState(() {
          _status = 'Could not inspect this file.';
          _error = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _scanUnknown() async {
    if (_running) return;
    setState(() {
      _running = true;
      _cancelled = false;
      _progress = 0;
      _status = 'Scanning for surviving media structure…';
      _error = null;
    });
    await _wake(true);
    try {
      final result = await scanRawVideo(widget.sourcePath,
        isCancelled: () => _cancelled || !mounted,
        onProgress: (value) {
          if (!mounted || _cancelled) return;
          if (value - _progress >= 0.02 || value >= 1) {
            setState(() => _progress = value);
          }
        },
      );
      if (!mounted || _cancelled) return;
      final streamCandidate = (result.psPackHeaders > 0 &&
          result.psVideoPackets > 0) || result.rawFormat != null;
      setState(() {
        _scan = result;
        _didDeepScan = true;
        _canAttempt = streamCandidate;
        _diagnostics = '$_diagnostics\n\n${result.diagnostic}';
        _status = 'Media-structure scan completed.';
        _advice = streamCandidate
            ? 'Potential media stream structure detected. '
              'A guided recovery attempt may help, but these byte '
              'markers do not guarantee decodable frames.'
            : 'No recognizable stream structures found. Trying Quick '
              'Repair and Deep Recovery again would likely repeat '
              'their previous failure. Manual tools remain available; '
              'this scan does not prove that recovery is impossible.';
      });
    } catch (e) {
      if (mounted && !_cancelled) {
        setState(() {
          _status = 'File scan failed.';
          _error = e.toString();
        });
      }
    } finally {
      await _wake(false);
      if (mounted) setState(() => _running = false);
    }
  }

  DateTime _lastProgressPaint = DateTime.fromMillisecondsSinceEpoch(0);

  Future<FFmpegSession> _execute(List<String> args) async {
    final completed = Completer<FFmpegSession>();
    _frames = 0;
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (finished) {
        if (!completed.isCompleted) completed.complete(finished);
      },
      null,
      (statistics) {
        if (!mounted) return;
        final count = statistics.getVideoFrameNumber();
        if (count <= _frames) return;
        final now = DateTime.now();
        if (now.difference(_lastProgressPaint).inMilliseconds < 500) return;
        _lastProgressPaint = now;
        setState(() => _frames = count);
      },
    );
    _activeSession = session.getSessionId();
    if (_cancelled && _activeSession != null) {
      await FFmpegKit.cancel(_activeSession);
    }
    try {
      return await completed.future;
    } finally {
      _activeSession = null;
    }
  }

  Future<bool> _verifyVideo(String path) async {
    if (_cancelled || !await File(path).exists()) return false;
    if (await File(path).length() < 4096) return false;
    if (mounted) setState(() => _status = 'Verifying decoded video frames…');
    // This checks that FFmpeg can actually decode initial frames, rather
    // than trusting an exit code and non-empty MP4/MKV alone.
    final session = await _execute(<String>[
      '-hide_banner', '-nostdin', '-loglevel', 'info',
      '-i', path, '-map', '0:v:0', '-an',
      '-frames:v', '8', '-f', 'null', '-',
    ]);
    final code = await session.getReturnCode();
    final logs = await session.getLogsAsString();
    final match = RegExp(r'frame=\s*(\d+)').allMatches(logs).toList();
    var loggedFrames = 0;
    for (final m in match) {
      final value = int.tryParse(m.group(1) ?? '') ?? 0;
      if (value > loggedFrames) loggedFrames = value;
    }
    final success = !_cancelled && ReturnCode.isSuccess(code) &&
        (_frames > 0 || loggedFrames > 0);
    if (!success) {
      _attemptLogs.add('Validation rejected ${p.basename(path)}: '
          'exit=$code, frames=$_frames, logged frames=$loggedFrames');
    }
    return success;
  }


  Future<_SeekCheck> _verifySeeking(String path) async {
    if (_cancelled) return _SeekCheck.failed;
    if (mounted) setState(() => _status = 'Checking five timeline positions…');
    double? seconds;
    try {
      final infoSession = await FFprobeKit.getMediaInformation(path)
          .timeout(const Duration(seconds: 15));
      final info = infoSession.getMediaInformation();
      seconds = double.tryParse(info?.getDuration() ?? '');
    } catch (e) {
      _attemptLogs.add('Unable to read media duration for seek checks: $e');
    }
    if (seconds == null || !seconds.isFinite || seconds < 12 ||
        seconds > 24 * 60 * 60) {
      _attemptLogs.add('Seek safety not verified: duration unknown, '
          'unreliable, or too short to sample.');
      return _SeekCheck.inconclusive;
    }
    // Seek to two widely separated positions through FFmpeg's demuxer.
    // This is a bounded smoke test, not proof the whole timeline works.
    for (final fraction in <double>[0.1, 0.3, 0.5, 0.75, 0.9]) {
      if (_cancelled) return _SeekCheck.failed;
      final target = (seconds * fraction).toStringAsFixed(3);
      try {
        final session = await _execute(<String>[
          '-hide_banner', '-nostdin', '-loglevel', 'info',
          '-ss', target,
          '-i', path, '-map', '0:v:0', '-an',
          '-frames:v', '3', '-f', 'null', '-',
        ]).timeout(const Duration(seconds: 25));
        final code = await session.getReturnCode();
        final logs = await session.getLogsAsString();
        final frameMatches = RegExp(r'frame=\s*(\d+)').allMatches(logs);
        var decoded = _frames;
        for (final match in frameMatches) {
          final frames = int.tryParse(match.group(1) ?? '') ?? 0;
          if (frames > decoded) decoded = frames;
        }
        if (!ReturnCode.isSuccess(code) || decoded <= 0) {
          _attemptLogs.add('Seek check at $target seconds failed: '
              'exit $code, decoded frames $decoded.');
          return _SeekCheck.failed;
        }
      } on TimeoutException {
        final id = _activeSession;
        if (id != null) {
          try {
            await FFmpegKit.cancel(id).timeout(const Duration(seconds: 5));
          } catch (_) {}
        }
        _attemptLogs.add('Seek check at $target seconds timed out.');
        return _SeekCheck.failed;
      } catch (e) {
        _attemptLogs.add('Seek check at $target seconds raised: $e');
        return _SeekCheck.failed;
      }
    }
    return _SeekCheck.passed;
  }

  Future<void> _deleteScratch(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _saveGallery(String path) async {
    if (!Platform.isAndroid) return;
    if (mounted) {
      setState(() {
        _gallerySaved = false;
        _exportLabel = null;
        _exportError = null;
        _status = 'Saving recovered copy to selected destination…';
      });
    }
    try {
      final destination = await RecoveryDestination.exportRecoveredVideo(path);
      if (mounted) {
        setState(() {
          _gallerySaved = true;
          _exportLabel = destination;
          _status = 'Recovered copy saved to $destination.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _exportError = 'Export failed: $e';
          _advice = 'The playable recovered copy remains in app storage. '
              'Choose a different output folder or retry saving; '
              'you do not need to recover the video again.';
        });
      }
    }
  }

  Future<void> _recover({bool deepOnly = false}) async {
    if (_running || !_canAttempt) return;
    setState(() {
      _running = true;
      _cancelled = false;
      _error = null;
      if (!deepOnly) _result = null;
      if (!deepOnly) _gallerySaved = false;
      _exportError = null;
      _seekVerified = false;
      _attemptLogs.clear();
      _status = 'Preparing recovery…';
    });
    await _wake(true);
    String? workFile;
    try {
      final dir = Directory(p.join(
          (await getApplicationDocumentsDirectory()).path,
          'DroidVidRecoveries'));
      await dir.create(recursive: true);
      final cleanName = p.basenameWithoutExtension(widget.sourcePath)
          .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final safeBase = cleanName.isEmpty ? 'video' :
          cleanName.substring(0, cleanName.length > 40 ? 40 : cleanName.length);
      final stem = '${safeBase}_guided_${DateTime.now().microsecondsSinceEpoch}';
      final rawFormat = _scan?.rawFormat;
      final forcedInput = _identified?.category == 'unknown'
          ? (_scan?.psPackHeaders != null && _scan!.psPackHeaders > 0
              ? 'mpeg' : rawFormat)
          : null;
      final inputArgs = <String>[
        '-hide_banner', '-nostdin', '-loglevel', 'warning',
        '-fflags', '+genpts+discardcorrupt', '-err_detect', 'ignore_err',
        '-probesize', '20000000', '-analyzeduration', '15000000',
        '-threads', '2',
        if (forcedInput != null) ...['-f', forcedInput],
        '-i', widget.sourcePath,
        '-map', '0:v:0', '-map', '0:a:0?', '-sn', '-dn',
      ];
      // Matroska supports more stream-copy combinations than MP4 (such as
      // MPEG-2 + MP2 audio). On timestamp-damaged sources, a lossless
      // container remux can preserve the same stalls. Reliable mode uses
      // decode/re-encode immediately rather than pretending that it
      // regenerates missing or broken keyframes.
      final attempts = (deepOnly || _preferReliablePlayback)
          ? <bool>[false] : <bool>[true, false];
      for (final quick in attempts) {
        if (_cancelled) break;
        final ext = quick ? 'mkv' : 'mp4';
        workFile = p.join(dir.path,
            '$stem${quick ? '.copy.working.mkv' : '.deep.working.mp4'}');
        final outputFile = p.join(dir.path, '$stem.$ext');
        setState(() => _status = quick
            ? 'Preserving original compressed quality (lossless remux)…'
            : 'Rebuilding playback timeline at high quality…');
        final args = <String>[
          ...inputArgs,
          if (quick) ...['-c', 'copy'] else ...[
            // MPEG program streams may change dimensions and contain
            // discontinuous timestamps. Rebuild from decodable frames.
            if (_identified?.format.startsWith('MPEG program stream') == true ||
                <String>{'.mpg', '.mpeg', '.m2v', '.vob'}
                    .contains(p.extension(widget.sourcePath).toLowerCase()))
              ...[
                '-vf',
                'scale=720:480:force_original_aspect_ratio=decrease,'
                'pad=720:480:(ow-iw)/2:(oh-ih)/2,setsar=1,'
                'setpts=N/(30*TB)',
                '-r', '30', '-fps_mode', 'cfr',
              ]
            else
              ...['-fps_mode', 'vfr'],
            '-c:v', 'mpeg4', '-q:v', '2', '-threads:v', '2',
            '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-b:a', '192k',
            '-af', 'aresample=async=1000:first_pts=0',
          ],
          '-avoid_negative_ts', 'make_zero',
          '-max_muxing_queue_size', '1024',
          if (!quick) ...['-movflags', '+faststart'],
          '-f', quick ? 'matroska' : 'mp4', '-n', workFile,
        ];
        final session = await _execute(args);
        final code = await session.getReturnCode();
        final success = ReturnCode.isSuccess(code) && !_cancelled;
        if (!success) {
          final log = await session.getLogsAsString();
          final detail = log.length > 700 ? log.substring(log.length - 700) : log;
          _attemptLogs.add(
              '${quick ? 'Lossless remux' : 'Deep rebuild'}: exit $code\n$detail');
        }
        final valid = success && await _verifyVideo(workFile);
        final seekCheck = valid
            ? await _verifySeeking(workFile)
            : _SeekCheck.failed;
        // A copy that decodes only its first few frames is not a verified
        // seekable repair. Try rebuilding its timestamps instead.
        if (valid && seekCheck == _SeekCheck.failed && quick) {
          _attemptLogs.add('Lossless copy decoded its first frames but '
              'failed seek checks; trying Deep Recovery.');
        }
        if (valid && (seekCheck != _SeekCheck.failed || !quick) &&
            !_cancelled) {
          await File(workFile).rename(outputFile);
          workFile = null;
          if (!mounted) return;
          setState(() {
            _result = outputFile;
            _lastWasLossless = quick;
            _seekVerified = seekCheck == _SeekCheck.passed;
            _status = seekCheck == _SeekCheck.passed
                ? 'Recovered copy passed initial decoding and five seek checks.'
                : 'Playable copy created; seeking remains unverified.';
            _advice = seekCheck == _SeekCheck.passed
                ? 'Sample positions decoded, but not every part of the '
                  'timeline was checked. Test backward/forward seeking on '
                  'your phone; the original remains untouched.'
                : 'This output decodes initial frames, but seeking was not '
                  'confirmed. Some damaged sections may still stall.';
          });
          await _saveGallery(outputFile);
          return;
        }
        await _deleteScratch(workFile);
        workFile = null;
      }
      if (!mounted) return;
      setState(() {
        _status = _cancelled ? 'Recovery cancelled.' :
            'No verified video was recovered.';
        _advice = _cancelled
            ? 'The original video is unchanged.'
            : 'Both supported recovery strategies failed to produce '
              'a file that passed the initial-frame decoding test. '
              'More specialized reconstruction may be required.';
        if (!_cancelled) _error = _attemptLogs.join('\n\n');
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = _cancelled ? 'Recovery cancelled.' :
              'Recovery could not finish.';
          if (!_cancelled) _error = e.toString();
        });
      }
    } finally {
      if (workFile != null) await _deleteScratch(workFile);
      await _wake(false);
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _cancel() async {
    if (!_running || _cancelled) return;
    setState(() {
      _cancelled = true;
      _status = 'Stopping…';
    });
    final id = _activeSession;
    if (id != null) {
      try { await FFmpegKit.cancel(id); } catch (_) {}
    }
  }

  Future<void> _manualTools() async {
    final output = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => RecoveryScreen(sourcePath: widget.sourcePath),
      ),
    );
    if (!mounted) return;
    if (output != null) Navigator.of(context).pop(output);
  }

  @override
  void dispose() {
    if (!_running) unawaited(_wake(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = p.basename(widget.sourcePath);
    return PopScope(
      canPop: !_running,
      child: Scaffold(
        appBar: AppBar(title: const Text('Recover & Record')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const Text('Guided Recovery',
                style: TextStyle(fontSize: 22,
                    fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Source: $label', maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 12),
              const Text(
                'First identify the file, then choose whether to preserve '
                'original compression or prioritize reliable navigation. '
                'Either approach creates a separate copy.',
              ),
              const SizedBox(height: 12),
              RecoveryDestinationPicker(disabled: _running),
              const SizedBox(height: 18),
              Text(_status, style: const TextStyle(fontSize: 16,
                  fontWeight: FontWeight.w600)),
              if (_identified != null) ...[
                const SizedBox(height: 8),
                Text('Detected format: ${_identified!.format}'),
              ],
              if (_canAttempt && !_running && _result == null) ...[
                const SizedBox(height: 10),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Prioritize reliable seeking'),
                  subtitle: const Text(
                    'On: rebuild decoded video at higher quality '
                    '(may take longer, use more storage). '
                    'Off: preserve compressed picture quality first '
                    '(seeking problems may remain).',
                  ),
                  value: _preferReliablePlayback,
                  onChanged: (value) =>
                      setState(() => _preferReliablePlayback = value),
                ),
              ],
              const SizedBox(height: 10),
              Text(_advice, style: const TextStyle(
                  color: Colors.amberAccent)),
              if (_running) ...[
                const SizedBox(height: 12),
                _progress > 0 && _progress < 1
                    ? LinearProgressIndicator(value: _progress)
                    : const LinearProgressIndicator(),
                if (_progress > 0 && _result == null)
                  Text('File scan: ${(_progress * 100).toStringAsFixed(0)}%'),
                if (_frames > 0)
                  Text('Decoder/encoder frames processed: $_frames'),
              ],
              const SizedBox(height: 16),
              if (!_running && !_canAttempt &&
                  !_didDeepScan && _identified?.category == 'unknown')
                FilledButton.icon(
                  onPressed: _scanUnknown,
                  icon: const Icon(Icons.manage_search),
                  label: const Text('Investigate unidentified file'),
                ),
              if (!_running && _canAttempt && _result == null)
                FilledButton.icon(
                  onPressed: _recover,
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Start guided recovery'),
                ),
              if (_running)
                OutlinedButton.icon(
                  onPressed: _cancelled ? null : _cancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(_cancelled ? 'Stopping…' : 'Cancel'),
                ),
              if (_result != null) ...[
                const SizedBox(height: 12),
                if (_seekVerified)
                  const Text('Five sample seeks passed; full playback untested.',
                      style: TextStyle(color: Colors.greenAccent))
                else
                  const Text('Seeking not confirmed; this file may still stall.',
                      style: TextStyle(color: Colors.amberAccent)),
                if (_gallerySaved)
                  Text('Saved to: ${_exportLabel ?? "Selected destination"}',
                      style: const TextStyle(color: Colors.greenAccent)),
                if (_exportError != null) ...[
                  Text(_exportError!,
                      style: const TextStyle(color: Colors.orangeAccent)),
                  OutlinedButton.icon(
                    onPressed: _running ? null : () async {
                      final path = _result;
                      if (path != null) await _saveGallery(path);
                    },
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Retry saving recovered copy'),
                  ),
                ],
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(_result),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play recovered copy'),
                ),
                const SizedBox(height: 8),
                if (!_running)
                  if (_lastWasLossless)
                    OutlinedButton.icon(
                      onPressed: () => _recover(deepOnly: true),
                      icon: const Icon(Icons.sync),
                      label: const Text('Rebuild for more reliable seeking'),
                    ),
              ],
              if (!_running)
                OutlinedButton.icon(
                  onPressed: _manualTools,
                  icon: const Icon(Icons.tune),
                  label: const Text('Manual repair and analysis tools'),
                ),
              if (_diagnostics.isNotEmpty)
                ExpansionTile(
                  title: const Text('Technical analysis'),
                  children: [
                    SelectableText(_diagnostics,
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              if (_error != null && _error!.isNotEmpty)
                ExpansionTile(
                  title: const Text('Recovery diagnostics'),
                  children: [
                    SelectableText(_error!,
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              const SizedBox(height: 14),
              const Text('Original file is never overwritten.',
                  style: TextStyle(color: Colors.white70)),
              const Text(
                'Initial-frame verification is not a complete playback, '
                'timestamp, or audio-sync test.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
