import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'recovery_segments.dart';
import 'mpeg_recovery_jump.dart';
import 'mpeg_auto_recovery.dart';
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

enum RecoveryMode { quickRepair, deepHighQuality, pastCrash, autoRegions, advancedAnalysis }

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
  bool _autoScanning = false;
  int _autoRegionTotal = 0;
  int _autoRegionDone = 0;
  int _autoSegments = 0;
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
  int _jumpPercent = 30;
  MpegJumpResult? _lastJump;
  String? _diagnostic;
  Duration _processed = Duration.zero;
  Timer? _segmentTimer;
  String? _segmentStem;
  String? _segmentDirectory;
  bool _segmentBusy = false;
  int _segmentCount = 0;
  int _closedSegments = 0;
  String? _latestSegment;

  Future<void> _checkSegments() async {
    final stem = _segmentStem;
    final folder = _segmentDirectory;
    if (stem == null || folder == null || _segmentBusy) { return; }
    _segmentBusy = true;
    try {
      final files = await RecoverySegments.list(folder, stem);
      final last = files.isEmpty ? null : p.basename(files.last.path);
      final closed = files.isEmpty ? 0 : files.length - 1;
      if (mounted) {
        setState(() {
          _segmentCount = files.length;
          _closedSegments = closed;
          _latestSegment = last;
        });
      }
      // App-private checkpoint survives a crash, unlike progress text.
      await File(p.join(folder, '$stem.checkpoint.txt')).writeAsString(
        'Deep Recovery checkpoint\n'
        'Source: $_name\n'
        'Updated: ${DateTime.now().toIso8601String()}\n'
        'Frames processed: $_frames\n'
        'Reported time: ${_duration(_processed)}\n'
        'Segments present: ${files.length}\n'
        'Earlier potentially finalized segments: $closed\n'
        'Last segment: ${last ?? "none"}\n'
        'Verify individual clips before relying on them.\n',
        flush: true,
      );
    } catch (e) {
      debugPrint('Segment checkpoint error: $e');
    } finally {
      _segmentBusy = false;
    }
  }

  void _stopSegmentTimer() {
    _segmentTimer?.cancel();
    _segmentTimer = null;
  }


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

  DateTime _lastRecoveryPaint = DateTime.fromMillisecondsSinceEpoch(0);

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
    if (_mode == RecoveryMode.autoRegions) {
      await _startAutoRegions();
      return;
    }
    if ((_mode == RecoveryMode.deepHighQuality || _mode == RecoveryMode.pastCrash) && Platform.isAndroid) {
      try {
        const storage = MethodChannel('droid_vid_player/storage');
        final available = await storage.invokeMethod<int>('availableBytes');
        final inputBytes = await File(widget.sourcePath).length();
        final reserve = inputBytes ~/ 2 + 1073741824;
        if (available == null || available < reserve) {
          if (mounted) {
            setState(() => _error = 'Insufficient free space. '
                'Reserve at least ${(reserve / 1073741824).toStringAsFixed(1)} GB '
                'before Deep Recovery. No output was written.');
          }
          return;
        }
      } catch (e) {
        if (mounted) {
          setState(() => _error = 'Free space check failed; '
              'recovery was not started: $e');
        }
        return;
      }
    }
    MpegJumpResult? byteJump;
    String? detectedVideoStream;
    if (_mode == RecoveryMode.pastCrash) {
      if (!{'.mpg', '.mpeg', '.vob'}.contains(
          p.extension(widget.sourcePath).toLowerCase())) {
        if (mounted) {
          setState(() => _error =
              'Recover Past Crash supports MPEG program streams only.');
        }
        return;
      }
      try {
        final detected = await MpegRecoveryJump.findDecodableStart(
          widget.sourcePath,
          percent: _jumpPercent,
          onProgress: (status) {
            if (mounted) setState(() => _status = status);
          },
        );
        byteJump = detected.jump;
        detectedVideoStream = detected.stream;
      } catch (error) {
        if (mounted) {
          setState(() => _error = '$error');
        }
        return;
      }
    }
    if (!mounted) return;
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
      _lastJump = byteJump;
      _diagnostic = null;
      _processed = Duration.zero;
      _segmentCount = 0;
      _closedSegments = 0;
      _latestSegment = null;
      _status = _mode == RecoveryMode.quickRepair
          ? 'Quick Repair: rebuilding the container without re-encoding…'
          : _mode == RecoveryMode.pastCrash
              ? 'Past-crash recovery: validated video stream, '
                'encoding later footage…'
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
          ? 'quick_repair' : _mode == RecoveryMode.pastCrash
              ? 'past_crash_${_jumpPercent}pct' : 'deep_high_quality';
      final stem = '${baseName}_${suffix}_${DateTime.now().millisecondsSinceEpoch}';
      // Preserve MPEG-2/MP2 codecs in MKV for lossless Quick Repair.
      // Deep Recovery continues re-encoding to a new MP4.
      final quick = _mode == RecoveryMode.quickRepair;
      final extension = quick ? 'mkv' : 'mp4';
      final outputFormat = quick ? 'matroska' : 'mp4';
      final finalPath = p.join(directory.path, '$stem.$extension');
      final partialPath = p.join(directory.path, '$stem.partial.$extension');
      final segmentPattern = p.join(directory.path, '$stem.segment_%05d.mkv');
      if (!quick) {
        _stopSegmentTimer();
        _segmentStem = stem;
        _segmentDirectory = directory.path;
        _segmentTimer = Timer.periodic(const Duration(seconds: 3),
            (_) => unawaited(_checkSegments()));
        unawaited(_checkSegments());
      }
      final logPath = p.join(directory.path, '$stem.log.txt');
      if (await File(finalPath).exists() || await File(partialPath).exists()) {
        throw StateError('A recovery output with this name already exists.');
      }
      _partialPath = partialPath;
      _logPath = logPath;
      await _wake(true);

      // Both modes run forward with no seeks.
      // Quick Repair copies compressed streams unchanged, so it cannot introduce
      // new generation loss. An MKV container accepts legacy codec pairs
      // better than MP4, but damaged packets and timestamps may remain.
      // Deep Recovery re-encodes decoded streams using a higher-quality MPEG-4
      // setting (q:v=2 rather than the previous q:v=5). This can still lose
      // quality, and it cannot reconstruct missing/damaged frames.
      final sharedArgs = <String>[
        '-hide_banner', '-nostdin', '-loglevel', 'warning',
        '-fflags', '+genpts+discardcorrupt',
        '-err_detect', 'ignore_err',
        '-threads', '2',
        if (byteJump != null) ...[
          '-skip_initial_bytes', '${byteJump.alignedByte}', '-f', 'mpeg',
        ],
        '-i', widget.sourcePath,
        '-map', detectedVideoStream ?? '0:v:0',
        if (detectedVideoStream == null) ...['-map', '0:a:0?'],
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
              '-c:v', 'mpeg4', '-q:v', '2', '-threads:v', '2',
              '-pix_fmt', 'yuv420p',
              '-c:a', 'aac', '-b:a', '192k',
              '-af', 'aresample=async=1000:first_pts=0',
            ];
      final args = quick ? <String>[
        ...sharedArgs,
        ...encodingArgs,
        '-avoid_negative_ts', 'make_zero',
        '-max_muxing_queue_size', '1024',
        if (!quick) ...['-movflags', '+faststart'],
        '-f', outputFormat, '-n', partialPath,
      ] : RecoverySegments.args(
          inputArgs: sharedArgs, pattern: segmentPattern,
          legacyMpeg: legacyMpeg);
      final session = await FFmpegKit.executeWithArgumentsAsync(
        args,
        (finished) {
          unawaited(_finish(finished, finalPath, partialPath, logPath, generation,
              segmentStem: quick ? null : stem));
        },
        null,
        (statistics) {
          if (!mounted || generation != _generation) return;
          final now = DateTime.now();
          if (now.difference(_lastRecoveryPaint).inMilliseconds < 500) return;
          _lastRecoveryPaint = now;
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
      _stopSegmentTimer();
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
    int generation, {String? segmentStem,
  }) async {
    try {
      _stopSegmentTimer();
      if (segmentStem != null) { await _checkSegments(); }
      final code = await session.getReturnCode();
      final logs = await session.getLogsAsString();
      final diagnostic = logs.length > 1400
          ? logs.substring(logs.length - 1400)
          : logs;
      await File(logPath).writeAsString(
        'Droid Vid Player sequential recovery (experimental)\n'
        'Mode: ${_mode == RecoveryMode.quickRepair ? 'Quick Repair' : 'Deep High Quality'}\n'
        'Source: ${widget.sourcePath}\n'
        'Byte jump: ${_lastJump?.alignedByte ?? 0} bytes\n'
        'Output: $finalPath\n'
        'Exit code: ${code?.toString() ?? 'none'}\n'
        'Cancelled: $_cancelling\n'
        'Processed output time: ${_duration(_processed)}\n'
        'Decoded/encoded frames: $_frames\n\n'
        'FFmpeg log:\n$logs',
        flush: true,
      );
      final segments = segmentStem == null ? <File>[] :
          await RecoverySegments.list(p.dirname(finalPath), segmentStem);
      final partial = File(partialPath);
      final hasPartial = segmentStem == null &&
          await partial.exists() && await partial.length() > 4096;
      final success = segmentStem == null &&
          ReturnCode.isSuccess(code) && hasPartial && !_cancelling;
      if (success) await partial.rename(finalPath);
      final verified = <String>[];
      if (segmentStem != null) {
        for (final file in segments) {
          if (_cancelling) break;
          if (await RecoverySegments.hasDecodableStart(file.path)) {
            verified.add(file.path);
          }
        }
      }
      await _wake(false);
      if (!mounted || generation != _generation) return;
      setState(() {
        _running = false;
        _logPath = logPath;
        _partialPath = hasPartial && !success ? partialPath : null;
        _resultPath = success ? finalPath :
            verified.isNotEmpty ? verified.first : null;
        _sessionId = null;
        _status = segmentStem != null
            ? 'Saved ${segments.length} MKV segments; ${verified.length} '
              'passed initial decoding. Inspect in Saved Recoveries.'
            : success
            ? (_mode == RecoveryMode.quickRepair
                ? 'Quick Repair completed without recompressing video.'
                : 'High-quality Deep Recovery completed.')
            : _cancelling ? 'Recovery stopped.' : 'Recovery incomplete.';
        _diagnostic = success ? null : diagnostic;
        _error = (success || segmentStem != null) ? null : _mode == RecoveryMode.quickRepair
            ? 'Quick Repair could not remux these streams to MKV. '
              'Some MPEG headers or packets may be damaged. '
              'Review the diagnostic; Deep Recovery may help.'
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


  Future<void> _startAutoRegions() async {
    if (_running || _savingGallery) return;
    if (!{'.mpg', '.mpeg', '.vob'}.contains(
        p.extension(widget.sourcePath).toLowerCase())) {
      setState(() => _error = 'Whole-file byte recovery currently supports '
          'MPEG program streams (.mpg, .mpeg, .vob).');
      return;
    }
    final generation = ++_generation;
    setState(() {
      _running = true;
      _cancelling = false;
      _cancelScan = false;
      _autoScanning = true;
      _scanProgress = 0;
      _autoRegionTotal = 0;
      _autoRegionDone = 0;
      _autoSegments = 0;
      _error = null;
      _diagnostic = null;
      _resultPath = null;
      _logPath = null;
      _status = 'Scanning 0% to 100% of the source bytes…';
    });
    try {
      await _wake(true);
      final regions = await MpegRecoveryJump.scanEntireFile(
        widget.sourcePath,
        isCancelled: () => _cancelScan || generation != _generation,
        onProgress: (fraction, message) {
          if (mounted && generation == _generation) {
            setState(() {
              _scanProgress = fraction;
              _status = message;
            });
          }
        },
      );
      if (!mounted || generation != _generation) return;
      if (_cancelScan) {
        setState(() => _status = 'Whole-file scan cancelled.');
        return;
      }
      setState(() {
        _autoScanning = false;
        _autoRegionTotal = regions.length;
      });
      if (regions.isEmpty) {
        setState(() => _status = 'Checked 0–100%: no decodable MPEG video '
            'samples were confirmed. No recovery files were made.');
        return;
      }
      final documents = await getApplicationDocumentsDirectory();
      final directory = Directory(p.join(documents.path, 'DroidVidRecoveries'));
      await directory.create(recursive: true);
      final rawName = p.basenameWithoutExtension(widget.sourcePath)
          .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final cleanName = rawName.isEmpty ? 'video' :
          (rawName.length > 40 ? rawName.substring(0, 40) : rawName);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final report = File(p.join(directory.path,
          '${cleanName}_autoscan_$timestamp.checkpoint.txt'));
      await report.writeAsString(
        'Automatic full-file MPEG recovery scan\n'
        'Source: ${widget.sourcePath}\n'
        'Sampled every 1% of bytes, across 0–100%.\n'
        'Candidate regions: ${regions.length}\n'
        'Note: boundaries are approximate; verify every recovered clip.\n\n',
        flush: true,
      );
      var saved = 0;
      var errors = 0;
      for (var i = 0; i < regions.length; i++) {
        if (_cancelScan || !mounted || generation != _generation) break;
        final region = regions[i];
        setState(() => _status = 'Recovering region ${i + 1}/'
            '${regions.length}, bytes ${region.fromPercent}%–'
            '${region.throughPercent}%…');
        try {
          if (Platform.isAndroid) {
            const channel = MethodChannel('droid_vid_player/storage');
            final free = await channel.invokeMethod<int>('availableBytes');
            final needed = region.length + region.length ~/ 2 +
                512 * 1024 * 1024;
            if (free == null || free < needed) {
              throw StateError('Not enough storage for temporary region '
                  'and output; need about '
                  '${(needed / 1073741824).toStringAsFixed(1)} GB free.');
            }
          }
          final stem = '${cleanName}_autoscan_region'
              '${(i + 1).toString().padLeft(3, "0")}_$timestamp';
          final result = await MpegAutoRecovery.recoverRegion(
            sourcePath: widget.sourcePath,
            region: region,
            directory: directory.path,
            stem: stem,
            isCancelled: () => _cancelScan || generation != _generation,
            onSession: (id) => _sessionId = id,
            onProgress: (message) {
              if (mounted && generation == _generation) {
                setState(() => _status =
                    'Region ${i + 1}/${regions.length}: $message');
              }
            },
          );
          saved += result.segments;
          if (!result.completed) errors++;
          await report.writeAsString(
            'Region ${i + 1} (${region.fromPercent}%–'
            '${region.throughPercent}%): '
            '${result.segments} segments; completed: ${result.completed}\n',
            mode: FileMode.append, flush: true,
          );
        } catch (error) {
          errors++;
          await report.writeAsString(
            'Region ${i + 1} error: $error\n',
            mode: FileMode.append, flush: true,
          );
        }
        if (mounted && generation == _generation) {
          setState(() {
            _autoRegionDone = i + 1;
            _autoSegments = saved;
          });
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _logPath = report.path;
        _status = _cancelScan
            ? 'Stopped. $saved segment files already saved; '
              'check Saved Recoveries → Segments.'
            : 'Scanned 0–100%. ${regions.length} candidate regions, '
              '$saved segments produced ($errors incomplete jobs). '
              'Open Saved Recoveries → Segments to review.';
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _status = 'Automatic recovery stopped.';
          _error = '$error';
        });
      }
    } finally {
      await _wake(false);
      if (mounted && generation == _generation) {
        setState(() {
          _running = false;
          _cancelling = false;
          _autoScanning = false;
          _sessionId = null;
        });
      }
    }
  }

  Future<void> _cancel() async {
    if (!_running || _cancelling) return;
    if (_mode == RecoveryMode.advancedAnalysis ||
        _mode == RecoveryMode.autoRegions) {
      setState(() {
        _cancelScan = true;
        _cancelling = true;
        _status = _mode == RecoveryMode.advancedAnalysis
            ? 'Stopping analysis…' : 'Stopping automatic recovery…';
      });
      final id = _sessionId;
      if (id != null) await FFmpegKit.cancel(id);
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
    _stopSegmentTimer();
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
                    value: RecoveryMode.pastCrash,
                    child: Text('Recover Past Crash — MPEG byte jump'),
                  ),
                  DropdownMenuItem(
                    value: RecoveryMode.autoRegions,
                    child: Text('Automatic 0–100% MPEG scan'),

                  ),

                  DropdownMenuItem(
                    value: RecoveryMode.advancedAnalysis,
                    child: Text('Advanced Analysis — unknown source'),
                  ),
                ],
              ),
              Text(
                _mode == RecoveryMode.quickRepair
                    ? 'Copies original streams into MKV without re-encoding '
                      'when the input is readable. Quality is preserved, '
                      'but damaged frames and bad timestamps may remain.'
                    : _mode == RecoveryMode.deepHighQuality
                        ? 'Decodes frames and audio into 90-second MKV segments. Requires '
                          'FFmpeg to recognize the input container.'
                        : _mode == RecoveryMode.pastCrash
                            ? 'Starts at a later position in the MPEG file '
                              'to bypass the repeatedly crashing region. '
                              'Creates fresh, separate segments.'
                            : _mode == RecoveryMode.autoRegions
                                ? 'Tests MPEG video at every 1% byte position '
                                  'from the beginning to the end, groups '
                                  'playable positions and recovers bounded '
                                  'regions as separate jobs. Probe results '
                                  'cannot guarantee every frame is playable.'
                                : 'Scans MP4 box markers and potential raw H.264/H.265 '
                          'headers without loading the full video in memory. '
                          'Analysis does not reconstruct a missing MP4 index, '
                          'and detected byte signatures do not guarantee '
                          'recoverable video.',
              ),
              if (_mode == RecoveryMode.pastCrash) ...[
                const SizedBox(height: 8),
                Text('Begin beyond $_jumpPercent% of source bytes'),
                Slider(
                  value: _jumpPercent.toDouble(),
                  min: 10, max: 90, divisions: 16,
                  label: '$_jumpPercent%',
                  onChanged: locked ? null :
                      (value) => setState(() => _jumpPercent = value.round()),
                ),
                const Text('Try 30% first. If that crashes, try 50% or 70%. '
                    'This is a byte position, not an exact timestamp. '
                    'Earlier recovery clips will not be overwritten.',
                    style: TextStyle(fontSize: 12)),
                if (_lastJump != null)
                  Text('Byte start: ${_lastJump!.alignedByte} / '
                      '${_lastJump!.sourceBytes}'),
              ],
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
                (_mode == RecoveryMode.advancedAnalysis ||
                     (_mode == RecoveryMode.autoRegions && _autoScanning))
                    ? LinearProgressIndicator(value: _scanProgress)
                    : const LinearProgressIndicator(),
                const SizedBox(height: 8),
                if (_mode == RecoveryMode.advancedAnalysis ||
                    (_mode == RecoveryMode.autoRegions && _autoScanning))
                  Text('Checked: ${(_scanProgress * 100).toStringAsFixed(0)}%')
                else if (_mode == RecoveryMode.autoRegions) ...[
                  Text('Recovery tasks: $_autoRegionDone/$_autoRegionTotal'),
                  Text('Segment files produced: $_autoSegments'),
                ] else ...[
                  Text('Processed output time: ${_duration(_processed)}'
                       '  ·  Frames: $_frames'),
                  if (_mode == RecoveryMode.deepHighQuality ||
                       _mode == RecoveryMode.pastCrash) ...[
                    Text('Segments created: $_segmentCount · '
                        'Earlier segments closed: $_closedSegments'),
                    if (_latestSegment != null)
                      Text('Latest segment: $_latestSegment'),
                    const Text('Closed segments must still pass a '
                        'decoding test.', style: TextStyle(fontSize: 12)),
                  ],
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
                          : _mode == RecoveryMode.pastCrash
                              ? 'Recover Past Crash'
                              : _mode == RecoveryMode.autoRegions
                                   ? 'Scan 0–100% and Recover'
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
