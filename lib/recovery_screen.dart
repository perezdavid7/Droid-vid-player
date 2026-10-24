import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'recovery_segments.dart';
import 'mpeg_recovery_jump.dart';
import 'mpeg_full_scan.dart';
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

enum RecoveryMode { quickRepair, deepHighQuality, pastCrash, advancedAnalysis }

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
  int _jumpPercent = 30;
  bool _fullScan = true;
  double _fullByteProgress = 0;
  int _fullProbeDone = 0;
  int _fullProbeTotal = 0;
  List<MpegRecoveryRegion> _fullRegions = [];
  List<String> _fullJobStatus = [];
  int _fullVerifiedSegments = 0;
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

  /// Analyze all source bytes and recover every independently verified region.
  /// Jobs are isolated by a temporary BYTE slice, rather than corrupt PTS.
  Future<void> _runFullRecovery() async {
    if (!{'.mpg', '.mpeg', '.vob'}.contains(
        p.extension(widget.sourcePath).toLowerCase())) {
      if (mounted) {
        setState(() => _error =
            'Full-file byte recovery currently supports MPEG program streams '
            '(.mpg, .mpeg, .vob). Other formats need their own scanners.');
      }
      return;
    }
    final generation = ++_generation;
    setState(() {
      _running = true;
      _cancelling = false;
      _cancelScan = false;
      _gallerySaved = false;
      _resultPath = null;
      _error = null;
      _diagnostic = null;
      _fullByteProgress = 0;
      _fullProbeDone = 0;
      _fullProbeTotal = 0;
      _fullRegions = [];
      _fullJobStatus = [];
      _fullVerifiedSegments = 0;
      _status = 'Scanning all source bytes from 0% to 100%…';
    });
    try {
      await _wake(true);
      final regions = await MpegFullScan.scan(
        widget.sourcePath,
        isCancelled: () => _cancelScan || generation != _generation,
        onByteProgress: (fraction) {
          if (!mounted || generation != _generation) return;
          if (fraction - _fullByteProgress >= 0.01 || fraction >= 1) {
            setState(() {
              _fullByteProgress = fraction;
              _status = 'Scanning every source byte: '
                  '${(fraction * 100).toStringAsFixed(0)}%. '
                  'Next: independently test video in candidate sections.';
            });
          }
        },
        onProbeProgress: (done, total) {
          if (!mounted || generation != _generation) return;
          setState(() {
            _fullProbeDone = done;
            _fullProbeTotal = total;
            _status = 'Entire source scanned (100%). '
                'Testing local video in candidate sections: $done / $total. '
                'A failed section does not stop the scan.';
          });
        },
      );
      if (_cancelScan || generation != _generation) {
        throw const MpegScanCancelled();
      }
      if (!mounted) return;
      setState(() {
        _fullRegions = regions;
        _fullJobStatus = List<String>.filled(
            regions.length, 'Waiting to recover');
        _status = regions.isEmpty
            ? 'Inspected 100% of source bytes; no locally decodable '
              'MPEG video sections were found.'
            : 'Full 0–100% scan complete. Found ${regions.length} '
              'separate recovery jobs; processing them one at a time.';
      });
      if (regions.isEmpty) return;

      final directory = Directory(p.join(
          (await getApplicationDocumentsDirectory()).path,
          'DroidVidRecoveries'));
      await directory.create(recursive: true);
      final tempDirectory = await getTemporaryDirectory();
      final cleanBase = p.basenameWithoutExtension(widget.sourcePath)
          .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final baseName = cleanBase.isEmpty ? 'video' :
          (cleanBase.length > 36 ? cleanBase.substring(0, 36) : cleanBase);
      final source = File(widget.sourcePath);
      var completed = 0;

      for (var i = 0; i < regions.length; i++) {
        if (_cancelScan) throw const MpegScanCancelled();
        final region = regions[i];
        final label = '${region.startPercent.toStringAsFixed(1)}–'
            '${region.endPercent.toStringAsFixed(1)}%';
        final stem = '${baseName}_fullscan_job'
            '${(i + 1).toString().padLeft(3, "0")}'
            '_${DateTime.now().millisecondsSinceEpoch}';
        final temporary = File(p.join(tempDirectory.path, '$stem.input.mpg'));
        final pattern = p.join(directory.path, '$stem.segment_%05d.mkv');
        final logFile = File(p.join(directory.path, '$stem.log.txt'));
        try {
          if (Platform.isAndroid) {
            const channel = MethodChannel('droid_vid_player/storage');
            final available = await channel.invokeMethod<int>('availableBytes');
            // Temporary source slice + output growth + working headroom.
            final reserve = region.length * 2 + 512 * 1024 * 1024;
            if (available == null || available < reserve) {
              _fullJobStatus[i] = 'Paused — insufficient free space';
              throw StateError('Not enough free space for job ${i + 1}. '
                  'Keep at least ${(reserve / 1073741824).toStringAsFixed(2)} '
                  'GB free. Earlier clips were preserved.');
            }
          }

          if (mounted) {
            setState(() {
            _fullJobStatus[i] = 'Copying isolated source bytes';
            _status = 'Job ${i + 1}/${regions.length} ($label): '
                'preparing an isolated input. Original is untouched.';
            });
          }
          await MpegFullScan.copyByteRange(
            source, temporary, region.startByte, region.endByte,
            isCancelled: () => _cancelScan,
          );
          if (_cancelScan) throw const MpegScanCancelled();

          _stopSegmentTimer();
          _segmentStem = stem;
          _segmentDirectory = directory.path;
          _segmentCount = 0;
          _closedSegments = 0;
          _frames = 0;
          _processed = Duration.zero;
          _segmentTimer = Timer.periodic(const Duration(seconds: 3),
              (_) => unawaited(_checkSegments()));
          if (mounted) {
            setState(() {
            _fullJobStatus[i] = 'Recovering video into MKV segments';
            _status = 'Job ${i + 1}/${regions.length} ($label): '
                'recovering into separate 90-second clips.';
            });
          }

          final finished = Completer<FFmpegSession>();
          final args = RecoverySegments.args(
            inputArgs: [
              '-hide_banner', '-nostdin', '-loglevel', 'warning',
              '-fflags', '+genpts+discardcorrupt',
              '-err_detect', 'ignore_err',
              '-threads', '2',
              '-f', 'mpeg', '-i', temporary.path,
              '-map', region.videoStream, '-sn', '-dn',
            ],
            pattern: pattern, legacyMpeg: true,
          );
          final session = await FFmpegKit.executeWithArgumentsAsync(
            args,
            (ended) {
              if (!finished.isCompleted) finished.complete(ended);
            },
            null,
            (stats) {
              if (!mounted || generation != _generation) return;
              final now = DateTime.now();
              if (now.difference(_lastRecoveryPaint).inMilliseconds < 500) {
                return;
              }
              _lastRecoveryPaint = now;
              setState(() {
                _processed = Duration(milliseconds:
                    stats.getTime().clamp(0, 1 << 53).toInt());
                _frames = stats.getVideoFrameNumber();
              });
            },
          );
          _sessionId = session.getSessionId();
          if (_cancelScan && _sessionId != null) {
            await FFmpegKit.cancel(_sessionId);
          }
          final ended = await finished.future;
          _sessionId = null;
          _stopSegmentTimer();
          await _checkSegments();

          final clips = await RecoverySegments.list(directory.path, stem);
          final verified = <String>[];
          for (final clip in clips) {
            if (_cancelScan) break;
            if (await RecoverySegments.hasDecodableStart(clip.path)) {
              verified.add(clip.path);
            }
          }
          final returnCode = await ended.getReturnCode();
          final logs = await ended.getLogsAsString();
          await logFile.writeAsString(
            'Full-file recovery job ${i + 1}/${regions.length}\n'
            'Source: ${widget.sourcePath}\n'
            'Byte range: ${region.startByte}–${region.endByte}\n'
            'Source fraction: $label\n'
            'Selected stream: ${region.videoStream}\n'
            'Result: ${verified.length} verified / ${clips.length} output clips\n'
            'FFmpeg exit: $returnCode\n\n$logs',
            flush: true,
          );
          _fullVerifiedSegments += verified.length;
          completed++;
          if (_resultPath == null && verified.isNotEmpty) {
            _resultPath = verified.first;
          }
          if (mounted) {
            setState(() {
            _fullJobStatus[i] =
                '${verified.length} verified / ${clips.length} clips';
            _status = 'Finished job ${i + 1}/${regions.length}. '
                'Continuing through remaining sections…';
            });
          }
        } on MpegScanCancelled {
          rethrow;
        } catch (e) {
          // A failed region is not a reason to give up on later sections.
          if (mounted) {
            setState(() {
            if (!_fullJobStatus[i].startsWith('Paused')) {
              _fullJobStatus[i] = 'Failed — $e';
            }
            _status = 'Job ${i + 1}/${regions.length} failed; '
                'continuing with the next region.';
            });
          }
        } finally {
          _stopSegmentTimer();
          _sessionId = null;
          try {
            if (await temporary.exists()) await temporary.delete();
          } catch (_) {}
        }
      }
      if (mounted) {
        setState(() {
        _status = 'Full 0–100% scan and queue finished: '
            '$completed / ${regions.length} jobs processed, '
            '$_fullVerifiedSegments locally verified video clips. '
            'Find every saved clip under Saved Recoveries → Segments.';
        });
      }
    } on MpegScanCancelled {
      if (mounted) {
        setState(() {
        _status = 'Full-file recovery stopped. Already saved segments remain.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
        _error = 'Full-file recovery stopped: $e';
        _status = 'Recovery was interrupted; existing clips were preserved.';
        });
      }
    } finally {
      _stopSegmentTimer();
      _sessionId = null;
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
    if (_mode == RecoveryMode.pastCrash && _fullScan) {
      await _runFullRecovery();
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

  Future<void> _cancel() async {
    if (!_running || _cancelling) return;
    if (_mode == RecoveryMode.advancedAnalysis ||
        (_mode == RecoveryMode.pastCrash && _fullScan)) {
      setState(() {
        _cancelScan = true;
        _cancelling = true;
        _status = 'Stopping scan/queue; saved clips will remain…';
      });
      final id = _sessionId;
      if (id != null) {
        try { await FFmpegKit.cancel(id); } catch (_) {}
      }
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
                            ? 'Full-file MPEG mode scans all source bytes '
                              '(0–100%), verifies local decoded video, '
                              'and recovers sections as separate bounded jobs. '
                              'Manual byte jump remains available.'
                            : 'Scans MP4 box markers and potential raw H.264/H.265 '
                          'headers without loading the full video in memory. '
                          'Analysis does not reconstruct a missing MP4 index, '
                          'and detected byte signatures do not guarantee '
                          'recoverable video.',
              ),
              if (_mode == RecoveryMode.pastCrash) ...[
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Full-file scan: 0–100%'),
                  subtitle: const Text(
                    'Examine the entire MPEG-PS file, test local frames, '
                    'and recover separate queued sections. Large files '
                    'can take a long time.'),
                  value: _fullScan,
                  onChanged: locked ? null :
                      (value) => setState(() => _fullScan = value),
                ),
                if (!_fullScan) ...[
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
                _mode == RecoveryMode.advancedAnalysis
                    ? LinearProgressIndicator(value: _scanProgress)
                    : _mode == RecoveryMode.pastCrash && _fullScan &&
                            _fullByteProgress < 1
                        ? LinearProgressIndicator(value: _fullByteProgress)
                        : const LinearProgressIndicator(),
                const SizedBox(height: 8),
                if (_mode == RecoveryMode.advancedAnalysis)
                  Text('Analyzed: ${(_scanProgress * 100).toStringAsFixed(0)}%')
                else if (_mode == RecoveryMode.pastCrash && _fullScan) ...[
                  Text('Source bytes inspected: '
                      '${(_fullByteProgress * 100).toStringAsFixed(0)}% · '
                      'Decoder checks: $_fullProbeDone/$_fullProbeTotal'),
                  Text('Verified clips: $_fullVerifiedSegments · '
                      'Current job frames: $_frames'),
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
              if (_mode == RecoveryMode.pastCrash && _fullScan &&
                  _fullRegions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Recovery jobs (${_fullRegions.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                for (var i = 0; i < _fullRegions.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      'Job ${i + 1}: '
                      '${_fullRegions[i].startPercent.toStringAsFixed(1)}–'
                      '${_fullRegions[i].endPercent.toStringAsFixed(1)}% '
                      '· ${_fullJobStatus[i]}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
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
                              ? (_fullScan
                                  ? 'Scan 0–100% & Recover Sections'
                                  : 'Recover Past Crash (Manual)')
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
                if (_mode == RecoveryMode.pastCrash && _fullScan)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'All clips are under Saved Recoveries → Segments. '
                      'The play/export buttons below refer only to the '
                      'first verified clip.',
                      style: TextStyle(color: Colors.amberAccent),
                    ),
                  ),
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
