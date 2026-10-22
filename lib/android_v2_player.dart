import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import 'guided_recovery_screen.dart';
import 'saved_recoveries_screen.dart';

/// V2: drag the picture through video frames. A stationary finger is a
/// stationary frame; this is intentionally scrubbing, not reverse playback.
class AndroidV2Player extends StatefulWidget {
  final Widget Function(BuildContext, String?)? legacyBuilder;

  const AndroidV2Player({super.key, this.legacyBuilder});

  @override
  State<AndroidV2Player> createState() => _AndroidV2PlayerState();
}

class _AndroidV2PlayerState extends State<AndroidV2Player> {
  static const formats = <String>{
    '.mp4', '.m4v', '.mov', '.mpg', '.mpeg', '.m2v', '.mkv', '.avi',
    '.webm', '.wmv', '.asf', '.ts', '.mts', '.m2ts', '.flv',
    '.3gp', '.vob', '.divx',
  };

  final _files = <String>[];
  VideoPlayerController? _video;
  int _index = 0;
  int _fileGeneration = 0;
  bool _loading = false;
  bool _controlsVisible = true;
  bool _fullScreen = false;
  bool _fill = false;
  int _rotation = 0;
  bool _repeat = false;
  String? _error;
  Timer? _hideTimer;

  static const _hardware = MethodChannel('droid_vid_player/hardware_scrub');
  int? _previewTexture;
  int? _previewSession;
  bool _previewAvailable = true;
  bool _previewOpening = false;
  bool _previewFrameReady = false;
  int _previewGeneration = 0;
  String? _previewSource;

  bool _scrubbing = false;
  bool _finishingScrub = false;
  bool _scrubOnPicture = false;
  bool _resumeAfterScrub = false;
  bool _seekBroken = false;
  Duration _scrubStart = Duration.zero;
  Duration _scrubTarget = Duration.zero;
  Duration? _pendingSeek;
  Future<void>? _seekTask;
  Future<void>? _pauseTask;
  int _scrubGeneration = 0;
  int _navigationGeneration = 0;
  bool _navigationRecoveryActive = false;
  double _totalDrag = 0;
  double _gestureWidth = 400;

  // One unified scale recognizer arbitrates all picture gestures. Using
  // onHorizontalDrag beside onScale would let a one-finger drag win the
  // gesture arena before the second pinch finger arrived.
  double _pictureZoom = 1;
  Offset _picturePan = Offset.zero;
  double _lastGestureScale = 1;
  bool _usedTwoFingers = false;
  double _gestureDx = 0;
  double _gestureDy = 0;
  bool _gestureScrub = false;
  static const double _maxPictureZoom = 6;

  bool _slowHolding = false;
  bool _slowWasPlaying = false;
  int _slowGeneration = 0;
  Future<void>? _slowStartTask;

  @override
  void initState() {
    super.initState();
    _hardware.setMethodCallHandler(_onHardwareEvent);
  }

  Future<void> _onHardwareEvent(MethodCall call) async {
    if (call.method == 'frameReady') {
      final details = Map<Object?, Object?>.from(call.arguments as Map);
      if (mounted && _scrubbing && _scrubOnPicture &&
          details['session'] == _previewSession) {
        setState(() => _previewFrameReady = true);
      }
    } else if (call.method == 'previewError') {
      _previewAvailable = false;
      if (mounted) setState(() => _previewFrameReady = false);
    }
  }

  // Open once per video instead of recreating a 4K HEVC decoder
  // every time the finger touches the picture. Initialization runs
  // asynchronously; no frames are decoded while playback is idle.
  Future<void> _openHardwarePreview(int generation, String source) async {
    if (_previewOpening || !_previewAvailable || !mounted) {
      return;
    }
    _previewOpening = true;
    try {
      final response = await _hardware.invokeMapMethod<String, dynamic>(
        'open', <String, Object>{'path': source});
      if (!mounted || generation != _previewGeneration ||
          _source != source) {
        // A newer open/close has superseded this response.
        return;
      }
      if (response != null) {
        setState(() {
          _previewTexture = (response['textureId'] as num).toInt();
          _previewSession = (response['session'] as num).toInt();
          _previewSource = source;
        });
        if (_scrubbing && _scrubOnPicture) {
          _requestHardwareFrame();
        }
      }
    } catch (_) {
      if (mounted && generation == _previewGeneration) {
        _previewAvailable = false;
        // Fallback to ExoPlayer without blocking ordinary navigation.
        if (_scrubbing && _scrubOnPicture) {
          _pendingSeek = _scrubTarget;
          _startSeekPump();
        }
      }
    } finally {
      _previewOpening = false;
    }
  }

  void _requestHardwareFrame() {
    if (_previewTexture == null || !_scrubbing ||
        !_scrubOnPicture) {
      return;
    }
    unawaited(_hardware.invokeMethod<void>('seek',
      <String, Object>{'timeMs': _scrubTarget.inMilliseconds}));
  }

  void _closeHardwarePreview() {
    _previewGeneration++;
    _previewTexture = null;
    _previewSession = null;
    _previewSource = null;
    _previewFrameReady = false;
    unawaited(_hardware.invokeMethod<void>('close').catchError((Object _) {}));
  }

  bool get _ready => _video?.value.isInitialized == true;
  bool get _playing => _video?.value.isPlaying == true;
  Duration get _position => _ready ? _video!.value.position : Duration.zero;
  Duration get _duration => _ready ? _video!.value.duration : Duration.zero;
  String? get _source => _files.isEmpty ? null : _files[_index];

  @override
  void dispose() {
    _fileGeneration++;
    _scrubGeneration++;
    _navigationGeneration++;
    _slowGeneration++;
    _hideTimer?.cancel();
    _hardware.setMethodCallHandler(null);
    _closeHardwarePreview();
    final player = _video;
    if (player != null) {
      player.removeListener(_onVideoChanged);
      unawaited(player.dispose());
    }
    if (_fullScreen) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  String _clock(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  String _relativeTime(Duration delta) {
    final sign = delta.isNegative ? '-' : '+';
    final absolute = Duration(milliseconds: delta.inMilliseconds.abs());
    return '($sign${_clock(absolute)})';
  }

  void _onVideoChanged() {
    if (!mounted || !_ready) {
      return;
    }
    if (_video!.value.hasError && _error == null) {
      _error = _video!.value.errorDescription ?? 'Video decoding failed.';
    }
    setState(() {});
  }

  void _showControls() {
    if (!mounted) {
      return;
    }
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _autoHide();
  }

  void _autoHide() {
    _hideTimer?.cancel();
    if (!_playing || _scrubbing || _finishingScrub || _slowHolding) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing && !_scrubbing &&
          !_finishingScrub && !_slowHolding) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  Future<void> _pickFile() async {
    try {
      final picked = await FilePicker.pickFiles(type: FileType.any);
      final paths = picked.map((file) => file.path).whereType<String>()
          .where((path) => formats.contains(p.extension(path).toLowerCase()))
          .toList();
      if (paths.isEmpty) {
        if (mounted) {
          setState(() => _error = 'Select a supported video file.');
        }
        return;
      }
      _files..clear()..addAll(paths);
      _index = 0;
      await _openFile();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'File picker: $e');
      }
    }
  }

  Future<void> _openFile() async {
    final source = _source;
    if (source == null) {
      return;
    }
    final generation = ++_fileGeneration;
    ++_scrubGeneration;
    ++_navigationGeneration;
    _navigationRecoveryActive = false;
    ++_slowGeneration;
    _hideTimer?.cancel();
    final old = _video;
    _closeHardwarePreview();
    _previewAvailable = true;
    setState(() {
      _video = null;
      _loading = true;
      _error = null;
      _seekBroken = false;
      _scrubbing = false;
      _finishingScrub = false;
      _scrubOnPicture = false;
      _pendingSeek = null;
      _seekTask = null;
      _slowHolding = false;
      _controlsVisible = true;
      _rotation = 0;
      _pictureZoom = 1;
      _picturePan = Offset.zero;
      _usedTwoFingers = false;
      _gestureScrub = false;
    });
    try {
      if (old != null) {
        old.removeListener(_onVideoChanged);
        await old.dispose();
      }
      if (!mounted || generation != _fileGeneration) {
        return;
      }
      final player = VideoPlayerController.file(File(source));
      _video = player;
      await player.initialize();
      if (!mounted || generation != _fileGeneration) {
        await player.dispose();
        return;
      }
      await player.setLooping(_repeat);
      player.addListener(_onVideoChanged);
      setState(() => _loading = false);
      await player.play();
      _autoHide();
      // Prewarm the native codec once while the video is already
      // available for normal playback. No decode runs until the first
      // finger move; prewarm happens without delaying ExoPlayer.
      if (mounted && generation == _fileGeneration) {
        unawaited(_openHardwarePreview(_previewGeneration, source));
      }
    } catch (e) {
      if (mounted && generation == _fileGeneration) {
        setState(() {
          _loading = false;
          _error = 'Android playback could not open this file: $e';
        });
      }
    }
  }

  Future<void> _switchFile(int delta) async {
    if (_files.length < 2) {
      return;
    }
    _index = (_index + delta + _files.length) % _files.length;
    await _openFile();
  }

  Future<void> _togglePlay() async {
    if (!_ready || _scrubbing || _finishingScrub) {
      return;
    }
    final player = _video!;
    if (player.value.isCompleted) {
      await player.seekTo(Duration.zero);
      await player.play();
    } else if (player.value.isPlaying) {
      await player.pause();
    } else {
      await player.play();
    }
    _showControls();
  }

  Future<void> _jump(int seconds) async {
    if (!_ready || _scrubbing || _finishingScrub ||
        _navigationRecoveryActive) {
      return;
    }
    final player = _video!;
    final wasPlaying = player.value.isPlaying;
    final fileGeneration = _fileGeneration;
    final navigation = ++_navigationGeneration;
    final ms = (_position.inMilliseconds + seconds * 1000)
        .clamp(0, _duration.inMilliseconds);
    try {
      await player.seekTo(Duration(milliseconds: ms))
          .timeout(const Duration(seconds: 5));
      if (!mounted || fileGeneration != _fileGeneration ||
          navigation != _navigationGeneration ||
          !identical(player, _video)) {
        return;
      }
      // Certain HEVC streams acknowledge a jump while remaining paused or
      // buffering. Preserve the play/pause state from BEFORE the jump.
      if (wasPlaying && !player.value.isPlaying) {
        await player.play();
      }
      _showControls();
      if (wasPlaying) {
        unawaited(_verifyNavigationAdvance(
          player, navigation, fileGeneration));
      }
    } catch (e) {
      if (mounted && navigation == _navigationGeneration) {
        setState(() => _error = 'Navigation failed: $e');
      }
    }
  }

  // A decoded frame can remain stuck even after ExoPlayer acknowledges
  // seekTo(). Watch for actual timeline advancement, and only once try a
  // short re-anchor seek. Never interfere with a new user action, a paused
  // video, slow motion, or the beginning/end of a scrub gesture.
  Future<void> _verifyNavigationAdvance(VideoPlayerController player,
      int navigation, int fileGeneration) async {
    if (!mounted || !identical(player, _video) || !_ready ||
        !player.value.isPlaying || _slowHolding || _scrubbing ||
        _finishingScrub) {
      return;
    }
    final initialMs = player.value.position.inMilliseconds;
    if (initialMs >= _duration.inMilliseconds - 2000) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    if (!mounted || navigation != _navigationGeneration ||
        fileGeneration != _fileGeneration ||
        !identical(player, _video) || !player.value.isPlaying ||
        _slowHolding || _scrubbing || _finishingScrub ||
        _navigationRecoveryActive) {
      return;
    }
    final movedMs = player.value.position.inMilliseconds - initialMs;
    if (movedMs >= 350) {
      return;
    }
    // During genuine buffering give the hardware decoder another moment
    // before attempting a recovery, rather than piling on seeks.
    if (player.value.isBuffering) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (!mounted || navigation != _navigationGeneration ||
          fileGeneration != _fileGeneration ||
          !identical(player, _video) || !player.value.isPlaying ||
          _slowHolding || _scrubbing || _finishingScrub ||
          _navigationRecoveryActive ||
          player.value.position.inMilliseconds - initialMs >= 350) {
        return;
      }
    }
    _navigationRecoveryActive = true;
    try {
      final currentMs = player.value.position.inMilliseconds;
      final retryMs = (currentMs + 180).clamp(0, _duration.inMilliseconds);
      if (retryMs != currentMs) {
        await player.seekTo(Duration(milliseconds: retryMs))
            .timeout(const Duration(seconds: 4));
      }
      if (mounted && navigation == _navigationGeneration &&
          fileGeneration == _fileGeneration &&
          identical(player, _video) && !player.value.isPlaying) {
        await player.play();
      }
    } catch (e) {
      if (mounted && navigation == _navigationGeneration) {
        setState(() => _error = 'Playback recovery failed: $e');
      }
    } finally {
      _navigationRecoveryActive = false;
    }
  }

  double _msPerPixel() {
    final durationMs = _duration.inMilliseconds.toDouble();
    final width = math.max(160.0, _gestureWidth);
    // A short drag can locate seconds, while long videos remain navigable.
    return (durationMs / width * 0.07).clamp(35.0, 450.0);
  }

  void _beginScrub({required bool picture, double width = 400}) {
    if (!_ready || _seekBroken || _scrubbing || _finishingScrub ||
        _slowHolding || _duration <= Duration.zero) {
      return;
    }
    final previouslyPlaying = _playing;
    ++_navigationGeneration;
    ++_scrubGeneration;
    _gestureWidth = width;
    _totalDrag = 0;
    _scrubStart = _position;
    _scrubTarget = _scrubStart;
    _resumeAfterScrub = previouslyPlaying;
    _pauseTask = previouslyPlaying ? _video!.pause() : Future<void>.value();
    _pendingSeek = null;
    _hideTimer?.cancel();
    if (picture) {
      _previewFrameReady = false; // Never show the previous swipe's frame.
      if (_previewAvailable && _previewTexture == null &&
          !_previewOpening && _source != null) {
        unawaited(_openHardwarePreview(_previewGeneration, _source!));
      }
    }
    setState(() {
      _scrubbing = true;
      _scrubOnPicture = picture;
      if (picture) {
        _controlsVisible = false;
      }
    });
  }

  void _moveScrub(Duration target) {
    if (!_scrubbing || !_ready) {
      return;
    }
    final ms = target.inMilliseconds.clamp(0, _duration.inMilliseconds);
    final next = Duration(milliseconds: ms);
    if (next == _scrubTarget) {
      return; // Stationary finger: keep displaying this exact frame.
    }
    setState(() => _scrubTarget = next);
    if (_scrubOnPicture && _previewAvailable &&
        _previewTexture != null && _previewSource == _source) {
      _requestHardwareFrame();
    } else if (_previewOpening && _scrubOnPicture &&
        _previewAvailable) {
      // Latest target is retained until the prewarmed decoder is ready.
    } else {
      _pendingSeek = next;
      _startSeekPump();
    }
  }

  void _startSeekPump() {
    if (_seekTask != null || _video == null) {
      return;
    }
    _seekTask = _runSeekPump(_scrubGeneration, _video!);
  }

  Future<void> _runSeekPump(
      int generation, VideoPlayerController video) async {
    try {
      await _pauseTask;
      while (mounted && generation == _scrubGeneration &&
          identical(video, _video)) {
        final target = _pendingSeek;
        _pendingSeek = null;
        if (target == null) {
          break;
        }
        // Coalesce repeated finger updates rather than flooding ExoPlayer
        // with outdated seeks. No frame advancement occurs between updates.
        await video.seekTo(target).timeout(const Duration(seconds: 6));
      }
    } catch (e) {
      if (mounted && generation == _scrubGeneration) {
        setState(() {
          _seekBroken = true;
          _error = 'Cannot seek reliably in this file: $e';
        });
      }
    } finally {
      _seekTask = null;
      if (mounted && _scrubbing && generation == _scrubGeneration &&
          _pendingSeek != null && !_seekBroken) {
        _startSeekPump();
      }
    }
  }

  void _scaleStart(ScaleStartDetails details) {
    _lastGestureScale = 1;
    _usedTwoFingers = details.pointerCount > 1;
    _gestureScrub = false;
    _gestureDx = 0;
    _gestureDy = 0;
  }

  void _scaleUpdate(ScaleUpdateDetails details, Size bounds) {
    // Two fingers always take precedence over seeking. Do not start any
    // more native preview/seek requests once a pinch has been detected.
    if (details.pointerCount > 1) {
      if (!_usedTwoFingers) {
        _usedTwoFingers = true;
        if (_gestureScrub) {
          _gestureScrub = false;
          unawaited(_finishScrub());
        }
      }
    }

    if (_usedTwoFingers || _pictureZoom > 1.001) {
      final oldZoom = _pictureZoom;
      final factor = details.scale / _lastGestureScale;
      final newZoom = (oldZoom * factor).clamp(1.0, _maxPictureZoom);
      final local = details.localFocalPoint;
      final delta = details.focalPointDelta;
      final scaleRatio = newZoom / oldZoom;
      final nextPan = Offset(
        local.dx - (local.dx - _picturePan.dx) * scaleRatio + delta.dx,
        local.dy - (local.dy - _picturePan.dy) * scaleRatio + delta.dy,
      );
      final maxX = bounds.width * (newZoom - 1);
      final maxY = bounds.height * (newZoom - 1);
      setState(() {
        _pictureZoom = newZoom;
        _picturePan = newZoom <= 1.001
            ? Offset.zero
            : Offset(
                nextPan.dx.clamp(-maxX, 0.0),
                nextPan.dy.clamp(-maxY, 0.0),
              );
      });
      _lastGestureScale = details.scale;
      return;
    }

    _lastGestureScale = details.scale;
    if (!_ready || _slowHolding || _finishingScrub) {
      return;
    }
    _gestureDx += details.focalPointDelta.dx;
    _gestureDy += details.focalPointDelta.dy;
    // Avoid seeking during vertical drags. The first horizontal movement
    // establishes the swipe without changing its existing sensitivity.
    if (!_gestureScrub) {
      if (_gestureDx.abs() < 8 || _gestureDx.abs() < _gestureDy.abs()) {
        return;
      }
      _beginScrub(picture: true, width: bounds.width);
      _gestureScrub = _scrubbing && _scrubOnPicture;
      if (!_gestureScrub) return;
    }

    _totalDrag += details.focalPointDelta.dx;
    final newMs = _scrubStart.inMilliseconds +
        (_totalDrag * _msPerPixel()).round();
    _moveScrub(Duration(milliseconds: newMs));
  }

  void _scaleEnd(ScaleEndDetails details) {
    if (_gestureScrub) {
      unawaited(_finishScrub());
    }
    _gestureScrub = false;
    _usedTwoFingers = false;
    _lastGestureScale = 1;
  }

  void _resetPictureZoom() {
    if (_pictureZoom <= 1.001 && _picturePan == Offset.zero) return;
    setState(() {
      _pictureZoom = 1;
      _picturePan = Offset.zero;
    });
  }

  Future<void> _finishScrub() async {
    if (!_scrubbing || _finishingScrub) {
      return;
    }
    final generation = _scrubGeneration;
    final player = _video;
    final target = _scrubTarget;
    final resume = _resumeAfterScrub;
    final wasPictureGesture = _scrubOnPicture;
    _pendingSeek = null;
    setState(() {
      _scrubbing = false;
      _finishingScrub = true;
    });
    try {
      await _seekTask;
      await _pauseTask;
      if (!mounted || generation != _scrubGeneration ||
          !identical(player, _video)) {
        return;
      }
      if (!_seekBroken) {
        await player!.seekTo(target).timeout(const Duration(seconds: 6));
      }
      if (resume) {
        await player!.play();
        if (mounted && generation == _scrubGeneration &&
            identical(player, _video)) {
          unawaited(_verifyNavigationAdvance(
            player, ++_navigationGeneration, _fileGeneration));
        }
      }
    } catch (e) {
      if (mounted && generation == _scrubGeneration) {
        setState(() => _error = 'Finishing the gesture failed: $e');
        if (resume && player != null && identical(player, _video)) {
          try {
            await player.play();
          } catch (_) {
            // Leave the decoder error visible.
          }
        }
      }
    } finally {
      if (mounted && generation == _scrubGeneration) {
        setState(() {
          _finishingScrub = false;
          _scrubOnPicture = false;
          _controlsVisible = !wasPictureGesture;
          // Preserve the initialized native codec for the next swipe.
          // It is released on file change or when the player closes.
          _previewFrameReady = false;
        });
        _autoHide();
      }
    }
  }

  void _startSlow(LongPressStartDetails details) {
    if (!_ready || _slowHolding || _scrubbing || _finishingScrub) {
      return;
    }
    final generation = ++_slowGeneration;
    _slowWasPlaying = _playing;
    _hideTimer?.cancel();
    setState(() {
      _slowHolding = true;
      _controlsVisible = false;
    });
    _slowStartTask = _applySlow(generation);
  }

  Future<void> _applySlow(int generation) async {
    final player = _video;
    try {
      await player!.setPlaybackSpeed(0.2);
      if (generation == _slowGeneration && !player.value.isPlaying) {
        await player.play();
      }
    } catch (e) {
      if (mounted && generation == _slowGeneration) {
        setState(() => _error = 'Slow motion failed: $e');
      }
    }
  }

  Future<void> _stopSlow() async {
    if (!_slowHolding) {
      return;
    }
    final generation = _slowGeneration;
    final player = _video;
    final restorePlay = _slowWasPlaying;
    setState(() => _slowHolding = false);
    try {
      await _slowStartTask;
      if (generation == _slowGeneration && player != null &&
          identical(player, _video)) {
        await player.setPlaybackSpeed(1);
        if (!restorePlay) {
          await player.pause();
        }
      }
    } catch (e) {
      if (mounted && generation == _slowGeneration) {
        setState(() => _error = 'Restoring normal speed failed: $e');
      }
    }
    if (mounted && generation == _slowGeneration) {
      _showControls();
    }
  }

  Future<void> _fullscreen() async {
    setState(() => _fullScreen = !_fullScreen);
    await SystemChrome.setEnabledSystemUIMode(
      _fullScreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    _showControls();
  }

  Future<void> _recover() async {
    final source = _source;
    if (source == null) {
      return;
    }

    // FFmpeg can need substantial native decoder, encoder and filter
    // memory for long recoveries. Pausing ExoPlayer is NOT sufficient:
    // it retains its codec, while V2 also keeps an independent MediaCodec
    // scrub-preview instance allocated between gestures.
    ++_fileGeneration;
    ++_scrubGeneration;
    ++_navigationGeneration;
    ++_slowGeneration;
    _hideTimer?.cancel();
    _closeHardwarePreview();
    final player = _video;
    player?.removeListener(_onVideoChanged);
    setState(() {
      _video = null;
      _scrubbing = false;
      _finishingScrub = false;
      _slowHolding = false;
      _loading = false;
      _controlsVisible = true;
    });
    try {
      await player?.dispose().timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('Playback cleanup before recovery: $e');
    }
    try {
      // The native preview cleanup is posted to its worker thread.
      // Wait for that cleanup before FFmpeg begins allocating memory.
      await _hardware.invokeMethod<void>('close')
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Scrub preview cleanup before recovery: $e');
    }
    if (!mounted) return;

    try {
      final recovered = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => GuidedRecoveryScreen(sourcePath: source),
        ),
      );
      if (!mounted) return;
      if (recovered != null && await File(recovered).exists()) {
        _files..clear()..add(recovered);
        _index = 0;
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Recovery could not open: $e');
      }
    } finally {
      if (mounted) {
        // Reload only after the recovery route closes, to avoid multiple
        // decoders running while FFmpeg is repairing a large file.
        await _openFile();
      }
    }
  }

  Future<void> _savedRecoveries() async {
    final file = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const SavedRecoveriesScreen(),
      ),
    );
    if (!mounted || file == null || !await File(file).exists()) return;
    _files..clear()..add(file);
    _index = 0;
    await _openFile();
  }

  Future<void> _compare() async {
    if (widget.legacyBuilder == null) {
      return;
    }
    final current = _source;
    await _video?.pause();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => widget.legacyBuilder!(ctx, current),
      ),
    );
    _showControls();
  }

  Widget _picture(VideoPlayerController player) => LayoutBuilder(
    builder: (context, constraints) {
      final dimensions = player.value.size;
      final width = dimensions.width > 0 ? dimensions.width : 16.0;
      final height = dimensions.height > 0 ? dimensions.height : 9.0;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_controlsVisible && _playing) {
            _hideTimer?.cancel();
            setState(() => _controlsVisible = false);
          } else {
            _showControls();
          }
        },
        // One recognizer manages both pinch and swipes so one finger
        // cannot steal the gesture from a two-finger zoom.
        onScaleStart: _scaleStart,
        onScaleUpdate: (details) => _scaleUpdate(
          details, constraints.biggest),
        onScaleEnd: _scaleEnd,
        onDoubleTap: _resetPictureZoom,
        onLongPressStart: _startSlow,
        onLongPressEnd: (_) => unawaited(_stopSlow()),
        onLongPressCancel: () => unawaited(_stopSlow()),
        child: SizedBox.expand(
          child: ClipRect(
            child: Transform(
              alignment: Alignment.topLeft,
              transform: Matrix4.identity()
                ..setEntry(0, 0, _pictureZoom)
                ..setEntry(1, 1, _pictureZoom)
                ..setEntry(0, 3, _picturePan.dx)
                ..setEntry(1, 3, _picturePan.dy),
              child: SizedBox.expand(
                child: FittedBox(
                  fit: _fill ? BoxFit.cover : BoxFit.contain,
                  child: RotatedBox(
                    quarterTurns: _rotation,
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: VideoPlayer(player),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _scrubOverlay() => IgnorePointer(
    child: SafeArea(
      bottom: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 14, left: 12, right: 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_clock(_scrubTarget), textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 23, fontWeight: FontWeight.w600,
                color: Colors.white,
                shadows: [Shadow(blurRadius: 5, color: Colors.black)])),
            Text(_relativeTime(_scrubTarget - _scrubStart),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14, color: Colors.white70,
                shadows: [Shadow(blurRadius: 5, color: Colors.black)])),
          ]),
        ),
      ),
    ),
  );

  Widget _toolbar() => SafeArea(
    bottom: false,
    child: Align(
      alignment: Alignment.topCenter,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.65),
        child: Row(children: [
          const SizedBox(width: 12),
          Expanded(child: Text(p.basename(_source ?? 'Droid Vid Player'),
            maxLines: 1, overflow: TextOverflow.ellipsis)),
          IconButton(
            tooltip: 'Open video',
            onPressed: () => unawaited(_pickFile()),
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: 'Recover & Record',
            onPressed: () => unawaited(_recover()),
            icon: const Icon(Icons.auto_fix_high),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (action) {
              if (action == 'fill') {
                setState(() => _fill = !_fill);
              } else if (action == 'repeat') {
                setState(() => _repeat = !_repeat);
                if (_ready) {
                  unawaited(_video!.setLooping(_repeat));
                }
              } else if (action == 'saved') {
                unawaited(_savedRecoveries());
              } else if (action == 'legacy') {
                unawaited(_compare());
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'saved',
                child: Text('Saved Recoveries')),
              PopupMenuItem(value: 'fill',
                child: Text(_fill ? 'Fit video' : 'Fill display')),
              PopupMenuItem(value: 'repeat',
                child: Text(_repeat ? 'Repeat off' : 'Repeat video')),
              if (widget.legacyBuilder != null)
                const PopupMenuItem(value: 'legacy',
                  child: Text('Compare legacy MPV player')),
            ],
          ),
        ]),
      ),
    ),
  );

  Widget _controls() {
    final durationMs = _duration.inMilliseconds.toDouble();
    final maxMs = durationMs > 0 ? durationMs : 1.0;
    final selected = _scrubbing || _finishingScrub
        ? _scrubTarget : _position;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.76),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Text(_clock(selected),
                  style: const TextStyle(fontSize: 12)),
                Expanded(child: Slider(
                  value: selected.inMilliseconds.toDouble().clamp(0, maxMs),
                  min: 0,
                  max: maxMs,
                  onChangeStart: !_ready || _seekBroken || durationMs <= 0
                      ? null
                      : (value) => _beginScrub(picture: false),
                  onChanged: !_ready || _seekBroken || durationMs <= 0
                      ? null
                      : (value) => _moveScrub(
                          Duration(milliseconds: value.round())),
                  onChangeEnd: !_ready || _seekBroken || durationMs <= 0
                      ? null
                      : (_) => unawaited(_finishScrub()),
                )),
                Text(_clock(_duration),
                  style: const TextStyle(fontSize: 12)),
              ]),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(tooltip: 'Previous',
                    onPressed: _files.length < 2 ? null
                        : () => unawaited(_switchFile(-1)),
                    icon: const Icon(Icons.skip_previous)),
                  IconButton(tooltip: 'Back 10 seconds',
                    onPressed: () => unawaited(_jump(-10)),
                    icon: const Icon(Icons.replay_10)),
                  IconButton.filled(
                    tooltip: _playing ? 'Pause' : 'Play',
                    onPressed: () => unawaited(_togglePlay()),
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow)),
                  IconButton(tooltip: 'Forward 10 seconds',
                    onPressed: () => unawaited(_jump(10)),
                    icon: const Icon(Icons.forward_10)),
                  IconButton(tooltip: 'Next',
                    onPressed: _files.length < 2 ? null
                        : () => unawaited(_switchFile(1)),
                    icon: const Icon(Icons.skip_next)),
                  IconButton(tooltip: 'Rotate video',
                    onPressed: () {
                      setState(() => _rotation = (_rotation + 1) % 4);
                      _showControls();
                    },
                    icon: const Icon(Icons.rotate_right)),
                  IconButton(tooltip: 'Fullscreen',
                    onPressed: () => unawaited(_fullscreen()),
                    icon: Icon(_fullScreen
                        ? Icons.fullscreen_exit : Icons.fullscreen)),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasFile = _source != null;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: !hasFile && !_fullScreen
          ? AppBar(title: const Text('Droid Vid Player V2')) : null,
      body: hasFile ? Stack(fit: StackFit.expand, children: [
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_ready && _video != null)
          _picture(_video!)
        else
          Center(child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(_error ?? 'Video unavailable.',
              textAlign: TextAlign.center))),
        if ((_scrubbing || _finishingScrub) &&
            _previewFrameReady && _previewTexture != null)
          Positioned.fill(child: IgnorePointer(
            child: Texture(textureId: _previewTexture!))),
        if (_scrubbing && _scrubOnPicture)
          _scrubOverlay(),
        if (_slowHolding)
          const Positioned(top: 80, left: 0, right: 0,
            child: Center(child: Text('Slow motion 0.2×'))),
        if (_controlsVisible && !_scrubbing)
          _toolbar(),
        if (_controlsVisible && _ready && !_scrubOnPicture)
          _controls(),
        if (_error != null && _ready)
          Positioned(top: 74, left: 14, right: 14,
            child: Material(
              color: Colors.red.shade900,
              borderRadius: BorderRadius.circular(10),
              child: Row(children: [
                Expanded(child: Padding(
                  padding: const EdgeInsets.all(9),
                  child: Text(_error!, maxLines: 3))),
                IconButton(
                  onPressed: () => setState(() => _error = null),
                  icon: const Icon(Icons.close)),
              ]),
            ),
          ),
        if (!_loading && !_ready)
          Positioned(bottom: 32, left: 0, right: 0,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FilledButton.icon(
                onPressed: () => unawaited(_pickFile()),
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose another video')),
              TextButton.icon(
                onPressed: () => unawaited(_recover()),
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Recover this video')),
            ]),
          ),
      ]) : Center(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.play_circle_outline, size: 60),
          const SizedBox(height: 14),
          const Text('Droid Vid Player V2',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          const Text('Drag left or right to find a frame.\n'
            'Hold still to stay there.\n'
            'Long-press for slow motion.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => unawaited(_savedRecoveries()),
            icon: const Icon(Icons.folder_copy_outlined),
            label: const Text('Saved Recoveries')),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => unawaited(_pickFile()),
            icon: const Icon(Icons.folder_open),
            label: const Text('Open video')),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12),
              child: Text(_error!,
                style: const TextStyle(color: Colors.amberAccent))),
        ],
      )),
    );
  }
}
