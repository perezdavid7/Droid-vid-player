import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import 'guided_recovery_screen.dart';
import 'reverse_frame_decoder.dart';

enum _SwipeMode { none, preview, forward, rewind }
enum _SwipeControl { preview, speed, continuous }

/// Primary Android playback screen. ExoPlayer is provided by video_player on
/// Android; the legacy MPV screen is optional for direct A/B comparisons.
/// FFmpeg recovery remains an independent workflow.
class AndroidMainPlayer extends StatefulWidget {
  final Widget Function(BuildContext, String?)? legacyBuilder;
  const AndroidMainPlayer({super.key, this.legacyBuilder});

  @override
  State<AndroidMainPlayer> createState() => _AndroidMainPlayerState();
}

class _AndroidMainPlayerState extends State<AndroidMainPlayer> {
  static const _extensions = <String>{
    '.mp4', '.m4v', '.mov', '.mpg', '.mpeg', '.m2v', '.mkv',
    '.avi', '.wmv', '.asf', '.webm', '.ts', '.mts', '.m2ts',
    '.flv', '.3gp', '.vob', '.vid', '.divx'
  };
  final _files = <String>[];
  VideoPlayerController? _controller;
  int _index = 0;
  int _openGeneration = 0;
  bool _loading = false;
  bool _fullScreen = false;
  bool _controlsVisible = true;
  bool _fill = false;
  int _turns = 0;
  int _repeat = 0; // 0=off, 1=one, 2=all.
  double _speed = 1.0;
  String? _error;
  Timer? _hideTimer;
  bool _advancing = false;

  final TransformationController _transform = TransformationController();
  double _zoom = 1;
  Size _viewport = Size.zero;

  bool _scrubbing = false;
  bool _swipeScrub = false;
  bool _resumeAfterScrub = false;
  Duration _scrubAt = Duration.zero;
  Duration? _pendingPreview;
  Timer? _previewTimer;
  Future<void>? _previewJob;
  DateTime _lastPreviewStarted = DateTime.fromMillisecondsSinceEpoch(0);
  static const _previewInterval = Duration(milliseconds: 140);
  Future<void>? _pauseJob;
  Future<void>? _nativeSeek;
  bool _seekFailed = false;
  bool _seeking = false;
  int _seekGeneration = 0;

  // Explicit modes prevent a horizontal drag from having two competing
  // meanings. Preview seeks in both directions, speed uses actual forward
  // playback rates. Native reverse decoding is not yet available.
  _SwipeControl _swipeControl = _SwipeControl.preview;
  _SwipeMode _swipeMode = _SwipeMode.none;
  bool _swipeActive = false;
  bool _swipeWasPlaying = false;
  bool _forwardRestoring = false;
  int _forwardGeneration = 0;
  double _forwardTravel = 0;
  double _forwardSpeed = 2.0;
  double _desiredForwardSpeed = 2.0;
  double _lastSwipeDx = 0;
  double _appliedForwardSpeed = 1.0;
  Future<void>? _forwardRateTask;
  Timer? _speedMeter;
  DateTime? _speedWall;
  Duration? _speedMedia;
  double? _observedSpeed;

  ReverseFrameDecoder? _reverseDecoder;
  ReverseFrameBatch? _reverseBatch;
  Uint8List? _reverseImage;
  Duration _reversePosition = Duration.zero;
  Timer? _reverseTimer;
  bool _reverseActive = false;
  bool _reverseLoading = false;
  bool _reverseWasPlaying = false;
  int _reverseGeneration = 0;
  int _reverseIndex = -1;
  Future<ReverseFrameBatch?>? _reversePrefetch;
  Duration? _reversePrefetchBefore;
  bool _reverseStopping = false;

  bool _slowHolding = false;
  bool _slowWasPlaying = false;
  Future<void>? _slowStart;
  bool _slowEnding = false;

  VideoPlayerController? get _video => _controller;
  bool get _ready => _video?.value.isInitialized == true;
  String? get _path => _files.isEmpty ? null : _files[_index];
  Duration get _length => _ready ? _video!.value.duration : Duration.zero;
  Duration get _position => _ready ? _video!.value.position : Duration.zero;
  bool get _playing => _video?.value.isPlaying == true;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
  }

  void _onTransformChanged() {
    if (!mounted) return;
    final next = _transform.value.getMaxScaleOnAxis();
    if ((next - _zoom).abs() > 0.02) setState(() => _zoom = next);
  }

  String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _wakeControls() {
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_playing || !_controlsVisible || _scrubbing || _slowHolding) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing && !_scrubbing && !_slowHolding) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _onVideoChanged() {
    if (!mounted || !_ready) return;
    final value = _video!.value;
    if (value.hasError && _error == null) {
      setState(() => _error = value.errorDescription ?? 'Playback error');
    }
    if (value.isCompleted && !_advancing && _repeat == 2 &&
        _files.length > 1) {
      _advancing = true;
      unawaited(_skipFile(1));
      return;
    }
    // Do not restart the auto-hide timer on each decoder position update.
    setState(() {});
  }

  Future<void> openFiles() async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.any);
      final paths = picked.map((f) => f.path)
          .whereType<String>()
          .where((path) => _extensions.contains(p.extension(path).toLowerCase()))
          .toList();
      if (paths.isEmpty) {
        if (mounted) {
          setState(() => _error = 'No supported video files were selected.');
        }
        return;
      }
      await _loadPlaylist(paths);
    } catch (e) {
      if (mounted) setState(() => _error = 'File picker failed: $e');
    }
  }

  Future<void> _loadPlaylist(List<String> paths, {int index = 0}) async {
    if (paths.isEmpty) return;
    _files..clear()..addAll(paths);
    _index = index.clamp(0, paths.length - 1);
    await _openCurrent();
  }

  Future<void> _openCurrent() async {
    final source = _path;
    if (source == null) return;
    final generation = ++_openGeneration;
    _cancelScrub();
    _stopReverse();
    _forwardGeneration++;
    _swipeMode = _SwipeMode.none;
    _swipeActive = false;
    _resetZoom();
    _stopSpeedMeter();
    _hideTimer?.cancel();
    final old = _controller;
    if (mounted) {
      setState(() {
        _controller = null;
        _loading = true;
        _error = null;
        _advancing = false;
        _turns = 0;
        _controlsVisible = true;
        _seekFailed = false;
      });
    }
    try {
      if (old != null) {
        old.removeListener(_onVideoChanged);
        await old.pause().timeout(const Duration(seconds: 2))
            .catchError((Object _) {});
        await old.dispose();
      }
      if (!mounted || generation != _openGeneration) return;
      final next = VideoPlayerController.file(File(source));
      _controller = next;
      await next.initialize();
      if (!mounted || generation != _openGeneration) {
        await next.dispose();
        return;
      }
      await next.setPlaybackSpeed(_speed);
      await next.setLooping(_repeat == 1);
      setState(() => _loading = false);
      next.addListener(_onVideoChanged);
      await next.play();
      _scheduleHide();
    } catch (e) {
      if (!mounted || generation != _openGeneration) return;
      setState(() {
        _loading = false;
        _error = 'Android player could not open this video: $e';
      });
    }
  }

  Future<void> _skipFile(int delta) async {
    if (_files.isEmpty) return;
    if (_files.length == 1) {
      if (_repeat == 0) return;
      await _restart();
      return;
    }
    final target = _index + delta;
    if (target < 0 || target >= _files.length) {
      if (_repeat != 2) {
        _advancing = false;
        return;
      }
      _index = (target + _files.length) % _files.length;
    } else {
      _index = target;
    }
    await _openCurrent();
  }

  Future<void> _restart() async {
    if (!_ready) return;
    if (!await _seekTo(Duration.zero)) return;
    await _video!.play();
    _wakeControls();
  }

  Future<void> _togglePlay() async {
    if (!_ready) return;
    if (_video!.value.isCompleted) {
      await _restart();
    } else if (_playing) {
      await _video!.pause();
      _wakeControls();
    } else {
      await _video!.play();
      _scheduleHide();
    }
  }

  Future<void> _setRate(double rate) async {
    if (!_ready) return;
    try {
      await _video!.setPlaybackSpeed(rate);
      if (mounted) setState(() => _speed = rate);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Playback speed $rate is unavailable: $e');
      }
    }
  }

  Future<void> _cycleRepeat() async {
    setState(() => _repeat = (_repeat + 1) % 3);
    if (_ready) await _video!.setLooping(_repeat == 1);
    _wakeControls();
  }

  Future<void> _seekSeconds(int amount) async {
    final target = _position + Duration(seconds: amount);
    if (await _seekTo(target)) _wakeControls();
  }

  // Native seek commands are serialized. On a timeout, do not send another
  // command to an engine which may still have a seek in progress.
  Future<bool> _seekTo(Duration target) async {
    final video = _video;
    if (!_ready || video == null || _seekFailed) return false;
    if (_nativeSeek != null) {
      try {
        await _nativeSeek!.timeout(const Duration(seconds: 6));
      } catch (_) {
        if (mounted) setState(() => _seekFailed = true);
        return false;
      }
    }
    final milliseconds = target.inMilliseconds.clamp(0, _length.inMilliseconds);
    final future = video.seekTo(Duration(milliseconds: milliseconds));
    _nativeSeek = future;
    if (mounted) setState(() => _seeking = true);
    try {
      await future.timeout(const Duration(seconds: 6));
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          _seekFailed = true;
          _error = 'Seeking stalled. Open the video again to reset the decoder. '
              'Details: $e';
        });
      }
      return false;
    } finally {
      if (identical(_nativeSeek, future)) _nativeSeek = null;
      if (mounted) setState(() => _seeking = false);
    }
  }

  void _cancelScrub() {
    _seekGeneration++;
    _previewTimer?.cancel();
    _previewTimer = null;
    _pendingPreview = null;
    _scrubbing = false;
    _swipeScrub = false;
  }

  void _beginScrub(Duration initial, {bool swipe = false}) {
    if (!_ready || _seekFailed || _scrubbing || _length <= Duration.zero) {
      return;
    }
    _seekGeneration++;
    _previewTimer?.cancel();
    _previewTimer = null;
    // video_player.pause() can update isPlaying synchronously. Capture
    // the prior state BEFORE asking the Android decoder to pause.
    final wasPlaying = _playing;
    _resumeAfterScrub = wasPlaying;
    _pauseJob = wasPlaying ? _video!.pause() : Future<void>.value();
    _lastPreviewStarted =
        DateTime.now().subtract(_previewInterval);
    _scrubAt = initial;
    _pendingPreview = null;
    _hideTimer?.cancel();
    setState(() {
      _scrubbing = true;
      _swipeScrub = swipe;
      _controlsVisible = !swipe;
    });
  }

  void _updateScrub(Duration target) {
    if (!_scrubbing) return;
    setState(() => _scrubAt = Duration(milliseconds:
        target.inMilliseconds.clamp(0, _length.inMilliseconds)));
    // Keep the latest finger position, but do not cancel every preview
    // timer as the finger moves. The old debounce only sought AFTER the
    // user stopped dragging, so the video frame never updated in motion.
    _pendingPreview = _scrubAt;
    _schedulePreview();
  }

  void _schedulePreview() {
    if (!_scrubbing || _seekFailed || _pendingPreview == null ||
        _previewTimer != null || _previewJob != null) {
      return;
    }
    final since = DateTime.now().difference(_lastPreviewStarted);
    final wait = since >= _previewInterval
        ? Duration.zero : _previewInterval - since;
    _previewTimer = Timer(wait, () {
      _previewTimer = null;
      if (!_scrubbing || _seekFailed || _pendingPreview == null ||
          _previewJob != null) {
        return;
      }
      _lastPreviewStarted = DateTime.now();
      _previewJob = _previewCurrent(_seekGeneration);
    });
  }

  Future<void> _previewCurrent(int generation) async {
    try {
      await _pauseJob;
      if (!mounted || !_scrubbing || generation != _seekGeneration ||
          _seekFailed) {
        return;
      }
      final target = _pendingPreview;
      _pendingPreview = null;
      if (target != null) {
        await _seekTo(target);
      }
    } catch (e) {
      if (mounted && generation == _seekGeneration) {
        setState(() => _error = 'Preview seek failed: $e');
      }
    } finally {
      _previewJob = null;
      if (mounted && generation == _seekGeneration) {
        // New finger positions collected during the native seek are
        // previewed next, never queued as competing native seeks.
        _schedulePreview();
      }
    }
  }

  Future<void> _endScrub() async {
    if (!_scrubbing) return;
    final generation = _seekGeneration;
    final video = _video;
    final target = _scrubAt;
    final resume = _resumeAfterScrub;
    _previewTimer?.cancel();
    _previewTimer = null;
    _pendingPreview = null;
    setState(() {
      _scrubbing = false;
      _swipeScrub = false;
      _controlsVisible = true;
    });
    try {
      // Wait for the last frame preview before the final precise position,
      // keeping all native seek commands serialized.
      await _previewJob;
      await _pauseJob;
      if (!mounted || generation != _seekGeneration ||
          !identical(video, _video)) {
        return;
      }
      if (!_seekFailed) await _seekTo(target);
    } catch (e) {
      if (mounted && generation == _seekGeneration) {
        setState(() => _error = 'Scrubbing stopped: $e');
      }
    } finally {
      // Resume whenever the video WAS playing at the start of the drag,
      // even if a preview/seek failed. Preserve a pre-existing pause.
      if (resume && mounted && generation == _seekGeneration &&
          identical(video, _video) && _ready) {
        try {
          await video!.play().timeout(const Duration(seconds: 4));
        } catch (e) {
          if (mounted) {
            setState(() => _error = 'Unable to resume playback: $e');
          }
        }
      }
      if (mounted && generation == _seekGeneration) _scheduleHide();
    }
  }

  void _selectSwipeControl(_SwipeControl selected) {
    if (_swipeActive || _scrubbing || _forwardRestoring) return;
    setState(() => _swipeControl = selected);
    _wakeControls();
  }

  void _beginSwipe(DragStartDetails details) {
    if (!_ready || _zoom > 1.02 || _slowHolding || _scrubbing ||
        _forwardRestoring || _swipeActive) {
      return;
    }
    _hideTimer?.cancel();
    _swipeActive = true;
    _swipeWasPlaying = _playing;
    _swipeMode = _SwipeMode.none;
    _forwardTravel = 0;
    _lastSwipeDx = 0;
    _forwardSpeed = 2.0;
    _desiredForwardSpeed = 2.0;
    _observedSpeed = null;
    if (_swipeControl == _SwipeControl.continuous) return;
    if (_swipeControl == _SwipeControl.preview) {
      // Preview mode does not change actual playback speed. Live seek
      // frames in EITHER direction as the finger moves.
      _swipeMode = _SwipeMode.preview;
      _beginScrub(_position, swipe: true);
    }
  }

  void _updateSwipe(DragUpdateDetails details) {
    if (!_swipeActive || !_ready || _viewport.width <= 0) return;
    final dx = details.delta.dx;
    _lastSwipeDx = dx;
    if (_swipeControl == _SwipeControl.continuous &&
        _swipeMode == _SwipeMode.none) {
      _forwardTravel += dx;
      if (_forwardTravel.abs() < 6) return;
      if (_forwardTravel < 0) {
        _swipeMode = _SwipeMode.rewind;
        unawaited(_startReverse());
      } else {
        _swipeMode = _SwipeMode.forward;
        _forwardGeneration++;
        _appliedForwardSpeed = _speed;
        _startSpeedMeter();
        setState(() => _controlsVisible = false);
      }
    }
    if (_swipeControl == _SwipeControl.continuous &&
        _swipeMode == _SwipeMode.rewind) {
      return;
    }
    if (_swipeMode == _SwipeMode.preview ||
        _swipeMode == _SwipeMode.rewind) {
      if (!_scrubbing) return;
      final msPerPixel = math.max(120.0,
          _length.inMilliseconds / math.max(100.0, _viewport.width) * 0.30);
      _updateScrub(_scrubAt + Duration(milliseconds:
          (dx * msPerPixel).round()));
      return;
    }

    // Speed mode is explicit. A swipe to the right really runs the
    // decoder faster; a swipe to the left retains seek preview, since
    // ExoPlayer has no regular continuous reverse-playback API.
    if (_swipeMode == _SwipeMode.none) {
      _forwardTravel += dx;
      if (_forwardTravel.abs() < 6) return;
      if (_forwardTravel > 0) {
        _swipeMode = _SwipeMode.forward;
        _forwardGeneration++;
        _appliedForwardSpeed = _speed;
        _hideTimer?.cancel();
        setState(() => _controlsVisible = false);
      } else {
        _swipeMode = _SwipeMode.rewind;
        _beginScrub(_position, swipe: true);
        _forwardTravel = 0;
        return;
      }
    }
    if (_swipeMode == _SwipeMode.forward) {
      _forwardTravel = (_forwardTravel + dx).clamp(0.0, _viewport.width);
      // A short one-handed drag now reaches noticeably different rates.
      // ExoPlayer might render fewer frames at 8x, but it receives a real
      // playback-rate command, not a skipped-timestamp seek.
      final nextRate = _forwardTravel < 45 ? 2.0
          : _forwardTravel < 110 ? 4.0 : 8.0;
      _desiredForwardSpeed = nextRate;
      if ((_forwardSpeed - nextRate).abs() > 0.01) {
        setState(() => _forwardSpeed = nextRate);
        unawaited(HapticFeedback.selectionClick());
      }
      _queueForwardRate();
    }
  }

  void _startSpeedMeter() {
    _speedMeter?.cancel();
    _speedWall = DateTime.now();
    _speedMedia = _position;
    _observedSpeed = null;
    _speedMeter = Timer.periodic(const Duration(milliseconds: 850), (_) {
      if (!mounted || !_swipeActive || _swipeMode != _SwipeMode.forward) {
        _stopSpeedMeter();
        return;
      }
      final now = DateTime.now();
      final previousTime = _speedWall;
      final previousMedia = _speedMedia;
      final position = _position;
      _speedWall = now;
      _speedMedia = position;
      if (previousTime == null || previousMedia == null) return;
      final elapsed = now.difference(previousTime).inMilliseconds;
      if (elapsed < 200) return;
      final moved = position.inMilliseconds - previousMedia.inMilliseconds;
      setState(() => _observedSpeed = math.max(0, moved / elapsed));
    });
  }

  void _stopSpeedMeter() {
    _speedMeter?.cancel();
    _speedMeter = null;
    _speedWall = null;
    _speedMedia = null;
  }

  void _queueForwardRate() {
    if (!_swipeActive || _swipeMode != _SwipeMode.forward ||
        _forwardRateTask != null) {
      return;
    }
    _forwardRateTask = _applyForwardRates(_forwardGeneration);
  }

  Future<void> _applyForwardRates(int generation) async {
    final video = _video;
    try {
      while (mounted && _swipeActive &&
          _swipeMode == _SwipeMode.forward &&
          generation == _forwardGeneration &&
          identical(video, _video) && _ready) {
        final desired = _desiredForwardSpeed;
        if ((desired - _appliedForwardSpeed).abs() < 0.01 &&
            video!.value.isPlaying) {
          break;
        }
        // Keep at most one native speed change in flight, avoiding decoder
        // command flooding during rapid finger motion.
        await video!.setPlaybackSpeed(desired)
            .timeout(const Duration(seconds: 3));
        _appliedForwardSpeed = desired;
        if (!video.value.isPlaying) {
          await video.play().timeout(const Duration(seconds: 3));
        }
        if ((desired - _desiredForwardSpeed).abs() < 0.01) break;
      }
    } catch (e) {
      if (mounted && _swipeMode == _SwipeMode.forward &&
          generation == _forwardGeneration) {
        setState(() => _error = 'Forward playback speed unavailable: $e');
      }
    } finally {
      _forwardRateTask = null;
      // A last speed change can arrive just before the previous command
      // completes. Queue that latest requested speed once, without overlap.
      if (mounted && _swipeActive &&
          _swipeMode == _SwipeMode.forward &&
          generation == _forwardGeneration &&
          (_desiredForwardSpeed - _appliedForwardSpeed).abs() > 0.01) {
        // If a native rate command errored, do not retry indefinitely.
        if (_error?.startsWith('Forward playback speed unavailable:') != true) {
          _queueForwardRate();
        }
      }
    }
  }

  Future<void> _endSwipe() async {
    if (!_swipeActive) return;
    final mode = _swipeMode;
    _swipeActive = false;
    _swipeMode = _SwipeMode.none;
    if (mode == _SwipeMode.rewind && _reverseActive) {
      await _finishReverse();
    } else if (mode == _SwipeMode.rewind || mode == _SwipeMode.preview) {
      await _endScrub();
    } else if (mode == _SwipeMode.forward) {
      _stopSpeedMeter();
      _forwardRestoring = true;
      final generation = _forwardGeneration;
      final video = _video;
      final wasPlaying = _swipeWasPlaying;
      try {
        await _forwardRateTask;
        if (generation == _forwardGeneration && identical(video, _video) &&
            _ready) {
          await video!.setPlaybackSpeed(_speed)
              .timeout(const Duration(seconds: 3));
          if (wasPlaying) {
            await video.play().timeout(const Duration(seconds: 3));
          } else {
            await video.pause().timeout(const Duration(seconds: 3));
          }
        }
      } catch (e) {
        if (mounted && generation == _forwardGeneration) {
          setState(() => _error = 'Could not restore playback speed: $e');
        }
      } finally {
        _forwardRestoring = false;
        if (mounted && generation == _forwardGeneration) {
          setState(() {
            _controlsVisible = true;
            _forwardSpeed = _speed;
          });
          _scheduleHide();
        }
      }
    } else {
      _wakeControls();
    }
  }

  Future<void> _startReverse() async {
    if (!_ready || _path == null || _reverseActive) return;
    final generation = ++_reverseGeneration;
    _reverseWasPlaying = _swipeWasPlaying;
    _reversePosition = _position;
    _reverseDecoder = ReverseFrameDecoder();
    setState(() {
      _reverseActive = true;
      _reverseLoading = true;
      _controlsVisible = false;
    });
    try {
      await _video!.pause();
      if (!mounted || !_reverseActive ||
          generation != _reverseGeneration) {
        return;
      }
      await _loadReverseBatch(generation);
    } catch (e) {
      if (mounted && generation == _reverseGeneration) {
        setState(() => _error = 'Reverse decoder: $e');
        await _finishReverse();
      }
    }
  }

  Future<void> _loadReverseBatch(int generation) async {
    final decoder = _reverseDecoder;
    final source = _path;
    if (decoder == null || source == null ||
        generation != _reverseGeneration || !_reverseActive) {
      return;
    }
    if (_reversePosition <= Duration.zero) {
      setState(() => _reverseLoading = false);
      return;
    }
    setState(() => _reverseLoading = true);
    final batch = await decoder.decode(
      sourcePath: source, before: _reversePosition,
      windowMillis: _reverseBatch == null
          ? ReverseFrameDecoder.initialChunkMillis
          : ReverseFrameDecoder.chunkMillis);
    if (!mounted || !_reverseActive ||
        generation != _reverseGeneration) {
      return;
    }
    if (batch == null || batch.images.isEmpty) {
      setState(() {
        _reverseLoading = false;
        _error = 'Reverse frames unavailable for this section.';
      });
      return;
    }
    _reverseBatch = batch;
    _reverseIndex = batch.images.length - 1;
    _reversePrefetch = null;
    _reversePrefetchBefore = null;
    _showReverseFrame(generation);
    _reverseTimer?.cancel();
    _reverseTimer = Timer.periodic(
      const Duration(milliseconds: 83), (_) => _showReverseFrame(generation));
  }

  void _showReverseFrame(int generation) {
    if (!_reverseActive || generation != _reverseGeneration ||
        !mounted) {
      return;
    }
    final batch = _reverseBatch;
    if (batch == null) return;
    if (_reverseIndex < 0) {
      _reverseTimer?.cancel();
      _reversePosition = batch.start;
      unawaited(_advanceReverseBatch(generation));
      return;
    }
    if (_reverseIndex <= 7 && _reversePrefetch == null &&
        batch.start > Duration.zero && _reverseDecoder != null &&
        _path != null) {
      _reversePrefetchBefore = batch.start;
      _reversePrefetch = _reverseDecoder!.decode(
        sourcePath: _path!, before: batch.start);
    }
    final index = _reverseIndex--;
    setState(() {
      _reverseImage = batch.images[index];
      _reversePosition = batch.positionFor(index);
      _reverseLoading = false;
    });
  }

  Future<void> _advanceReverseBatch(int generation) async {
    final pending = _reversePrefetch;
    final before = _reversePrefetchBefore;
    if (pending == null || before == null) {
      await _loadReverseBatch(generation);
      return;
    }
    if (mounted && _reverseActive && generation == _reverseGeneration) {
      setState(() => _reverseLoading = true);
    }
    final batch = await pending;
    if (!mounted || !_reverseActive || generation != _reverseGeneration) {
      return;
    }
    _reversePrefetch = null;
    _reversePrefetchBefore = null;
    if (batch == null || batch.images.isEmpty) {
      await _loadReverseBatch(generation);
      return;
    }
    _reverseBatch = batch;
    _reverseIndex = batch.images.length - 1;
    _showReverseFrame(generation);
    _reverseTimer = Timer.periodic(
      const Duration(milliseconds: 83), (_) => _showReverseFrame(generation));
  }

  void _stopReverse() {
    _reverseGeneration++;
    _reverseTimer?.cancel();
    _reverseTimer = null;
    _reverseActive = false;
    _reverseLoading = false;
    _reverseBatch = null;
    _reverseImage = null;
    _reverseIndex = -1;
    _reversePrefetch = null;
    _reversePrefetchBefore = null;
    final decoder = _reverseDecoder;
    _reverseDecoder = null;
    if (decoder != null) unawaited(decoder.dispose());
  }

  Future<void> _finishReverse() async {
    if (!_reverseActive || _reverseStopping) return;
    _reverseStopping = true;
    final position = _reversePosition;
    final resume = _reverseWasPlaying;
    final video = _video;
    _stopReverse();
    if (mounted) setState(() => _controlsVisible = true);
    try {
      if (video != null && mounted && _ready) {
        await _seekTo(position);
        if (resume) await video.play();
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Reverse exit failed: $e');
    } finally {
      _reverseStopping = false;
      _scheduleHide();
    }
  }

  void _beginSlow(LongPressStartDetails details) {
    if (!_ready || _scrubbing || _slowHolding) return;
    _slowWasPlaying = _playing;
    _hideTimer?.cancel();
    setState(() {
      _slowHolding = true;
      _controlsVisible = false;
    });
    _slowStart = _activateSlow();
  }

  Future<void> _activateSlow() async {
    try {
      await _video!.setPlaybackSpeed(0.5);
      if (!_playing) await _video!.play();
    } catch (e) {
      if (mounted) setState(() => _error = 'Slow motion unavailable: $e');
    }
  }

  Future<void> _endSlow() async {
    if (!_slowHolding || _slowEnding) return;
    _slowEnding = true;
    try {
      await _slowStart;
      if (_ready) {
        await _video!.setPlaybackSpeed(_speed);
        if (!_slowWasPlaying) await _video!.pause();
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not restore speed: $e');
    } finally {
      _slowEnding = false;
      if (mounted) {
        setState(() {
          _slowHolding = false;
          _controlsVisible = true;
        });
      }
      _scheduleHide();
    }
  }

  void _zoomBy(double factor) {
    if (_viewport.isEmpty) return;
    final target = (_zoom * factor).clamp(1.0, 6.0);
    if (target <= 1.01) {
      _resetZoom();
      return;
    }
    final focal = Offset(_viewport.width / 2, _viewport.height / 2);
    final scene = _transform.toScene(focal);
    _transform.value = Matrix4.identity()
      ..setEntry(0, 0, target)
      ..setEntry(1, 1, target)
      ..setEntry(0, 3, (focal.dx - scene.dx * target)
          .clamp(_viewport.width * (1 - target), 0.0))
      ..setEntry(1, 3, (focal.dy - scene.dy * target)
          .clamp(_viewport.height * (1 - target), 0.0));
    _wakeControls();
  }

  void _resetZoom() {
    _transform.value = Matrix4.identity();
  }

  Future<void> _toggleFullScreen() async {
    setState(() => _fullScreen = !_fullScreen);
    await SystemChrome.setEnabledSystemUIMode(
        _fullScreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    _wakeControls();
  }

  Future<void> _openRecovery() async {
    final source = _path;
    if (source == null) return;
    try {
      await _video?.pause();
      if (!mounted) return;
      final recovered = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => GuidedRecoveryScreen(sourcePath: source),
        ),
      );
      if (!mounted) return;
      if (recovered != null && await File(recovered).exists()) {
        await _loadPlaylist([recovered]);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Recovery could not start: $e');
    }
  }

  Future<void> _openLegacy() async {
    if (widget.legacyBuilder == null) return;
    final source = _path;
    await _video?.pause();
    if (!mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (ctx) => widget.legacyBuilder!(ctx, source)));
    _wakeControls();
  }

  @override
  void dispose() {
    _openGeneration++;
    _cancelScrub();
    _stopReverse();
    _forwardGeneration++;
    _swipeActive = false;
    _swipeMode = _SwipeMode.none;
    _hideTimer?.cancel();
    _stopSpeedMeter();
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    final video = _controller;
    if (video != null) {
      video.removeListener(_onVideoChanged);
      unawaited(video.dispose());
    }
    if (_fullScreen) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  Widget _videoSurface(VideoPlayerController video) => LayoutBuilder(
    builder: (context, constraints) {
      _viewport = constraints.biggest;
      final size = video.value.size;
      final width = size.width > 0 ? size.width : 16.0;
      final height = size.height > 0 ? size.height : 9.0;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_controlsVisible && _playing) {
            _hideTimer?.cancel();
            setState(() => _controlsVisible = false);
          } else {
            _wakeControls();
          }
        },
                onDoubleTap: () {
          if (_zoom > 1.05) {
            _resetZoom();
          } else {
            _zoomBy(2.5);
          }
        },
        onLongPressStart: _beginSlow,
        onLongPressEnd: (_) => unawaited(_endSlow()),
        onLongPressCancel: () => unawaited(_endSlow()),
        onHorizontalDragStart: _zoom > 1.02 ? null : _beginSwipe,
        onHorizontalDragUpdate: _zoom > 1.02 ? null : _updateSwipe,
        onHorizontalDragEnd: _zoom > 1.02 ? null : (_) =>
            unawaited(_endSwipe()),
        onHorizontalDragCancel: _zoom > 1.02 ? null : () =>
            unawaited(_endSwipe()),
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: 6,
          panEnabled: _zoom > 1.02,
          scaleEnabled: true,
          child: SizedBox.expand(child: ClipRect(
            child: FittedBox(
              fit: _fill ? BoxFit.cover : BoxFit.contain,
              child: RotatedBox(
                quarterTurns: _turns,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: VideoPlayer(video),
                ),
              ),
            ),
          )),
        ),
      );
    },
  );

  Widget _transport() => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        tooltip: 'Previous video',
        onPressed: _files.length < 2 ? null : () =>
            unawaited(_skipFile(-1)),
        icon: const Icon(Icons.skip_previous),
      ),
      IconButton(
        tooltip: 'Rewind 10 seconds',
        onPressed: !_ready || _seekFailed || _seeking ? null : () =>
            unawaited(_seekSeconds(-10)),
        icon: const Icon(Icons.replay_10),
      ),
      IconButton.filled(
        tooltip: _playing ? 'Pause' : 'Play',
        onPressed: !_ready ? null : () => unawaited(_togglePlay()),
        icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
      ),
      IconButton(
        tooltip: 'Fast forward 10 seconds',
        onPressed: !_ready || _seekFailed || _seeking ? null : () =>
            unawaited(_seekSeconds(10)),
        icon: const Icon(Icons.forward_10),
      ),
      IconButton(
        tooltip: 'Next video',
        onPressed: _files.length < 2 ? null : () =>
            unawaited(_skipFile(1)),
        icon: const Icon(Icons.skip_next),
      ),
      IconButton(
        tooltip: 'Restart current video',
        onPressed: !_ready ? null : () => unawaited(_restart()),
        icon: const Icon(Icons.replay),
      ),
    ],
  );

  Widget _displayOptions() => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 4,
    children: [
      DropdownButton<double>(
        value: _speed,
        underline: const SizedBox.shrink(),
        dropdownColor: const Color(0xFF24212A),
        items: const [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 4.0]
          .map((rate) => DropdownMenuItem<double>(
              value: rate, child: Text('$rate×'))).toList(),
        onChanged: !_ready ? null : (v) {
          if (v != null) unawaited(_setRate(v));
        },
      ),
      IconButton(
        tooltip: _repeat == 0 ? 'Repeat off' :
            _repeat == 1 ? 'Repeat one' : 'Repeat playlist',
        onPressed: () => unawaited(_cycleRepeat()),
        icon: Icon(_repeat == 1 ? Icons.repeat_one : Icons.repeat,
          color: _repeat == 0 ? Colors.white70 : Colors.tealAccent),
      ),
      IconButton(
        tooltip: 'Rotate video 90 degrees',
        onPressed: () {
          setState(() => _turns = (_turns + 1) % 4);
          _resetZoom();
          _wakeControls();
        },
        icon: const Icon(Icons.rotate_right),
      ),
      IconButton(
        tooltip: _fill ? 'Fit video' : 'Fill display',
        onPressed: () {
          setState(() => _fill = !_fill);
          _resetZoom();
          _wakeControls();
        },
        icon: Icon(_fill ? Icons.fit_screen : Icons.zoom_out_map),
      ),
      IconButton(
        tooltip: 'Zoom out',
        onPressed: _zoom <= 1.01 ? null : () => _zoomBy(1 / 1.5),
        icon: const Icon(Icons.zoom_out),
      ),
      IconButton(
        tooltip: 'Zoom in',
        onPressed: _zoom >= 5.99 ? null : () => _zoomBy(1.5),
        icon: const Icon(Icons.zoom_in),
      ),
      IconButton(
        tooltip: 'Reset zoom and pan',
        onPressed: _zoom <= 1.01 ? null : () {
          _resetZoom();
          _wakeControls();
        },
        icon: const Icon(Icons.center_focus_strong),
      ),
    ],
  );

  Widget _timeline() {
    final totalMs = _length.inMilliseconds.toDouble();
    final max = totalMs > 0 ? totalMs : 1.0;
    final current = _reverseActive ? _reversePosition : (_scrubbing ? _scrubAt : _position);
    final value = current.inMilliseconds.toDouble().clamp(0.0, max);
    return Row(children: [
      Text(_clock(current), style: const TextStyle(fontSize: 12)),
      Expanded(child: Slider(
        value: value, max: max,
        onChangeStart: !_ready || _seekFailed || totalMs <= 0 ? null :
            (v) => _beginScrub(Duration(milliseconds: v.round())),
        onChanged: !_scrubbing && (_seekFailed || !_ready) ? null :
            (v) => _updateScrub(Duration(milliseconds: v.round())),
        onChangeEnd: !_ready || _seekFailed ? null :
            (_) => unawaited(_endScrub()),
      )),
      Text(totalMs > 0 ? _clock(_length) : '--:--',
          style: const TextStyle(fontSize: 12)),
    ]);
  }

  Widget _swipeControlPicker() => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Text('Swipe:', style: TextStyle(fontSize: 12)),
      const SizedBox(width: 8),
      ChoiceChip(
        label: const Text('Preview'),
        selected: _swipeControl == _SwipeControl.preview,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => _selectSwipeControl(_SwipeControl.preview),
      ),
      const SizedBox(width: 8),
      ChoiceChip(
        label: const Text('Continuous'),
        selected: _swipeControl == _SwipeControl.continuous,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => _selectSwipeControl(_SwipeControl.continuous),
      ),
      const SizedBox(width: 8),
      ChoiceChip(
        label: const Text('Speed 2× / 4× / 8×'),
        selected: _swipeControl == _SwipeControl.speed,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => _selectSwipeControl(_SwipeControl.speed),
      ),
    ],
  );

  Widget _overlayControls() => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(8, 0, 8, 20),
    child: Align(alignment: Alignment.bottomCenter, child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!_scrubbing) _transport(),
          if (!_scrubbing) _displayOptions(),
          if (!_scrubbing) _swipeControlPicker(),
          _timeline(),
          if (_seekFailed)
            const Text('Seeking stalled. Reopen the video to reset playback.',
                style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
        ]),
      ),
    )),
  );

  Widget _toolbar() => SafeArea(
    bottom: false,
    minimum: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        const SizedBox(width: 10),
        Expanded(child: Text(p.basename(_path ?? 'Droid Vid Player'),
            maxLines: 1, overflow: TextOverflow.ellipsis)),
        IconButton(
          tooltip: 'Open local videos',
          onPressed: () => unawaited(openFiles()),
          icon: const Icon(Icons.folder_open),
        ),
        IconButton(
          tooltip: 'Recover & Record this video',
          onPressed: () => unawaited(_openRecovery()),
          icon: const Icon(Icons.auto_fix_high),
        ),
        IconButton(
          tooltip: _fullScreen ? 'Exit fullscreen' : 'Fullscreen',
          onPressed: () => unawaited(_toggleFullScreen()),
          icon: Icon(_fullScreen ? Icons.fullscreen_exit : Icons.fullscreen),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (action) {
            if (action == 'legacy') unawaited(_openLegacy());
            if (action == 'reload') unawaited(_openCurrent());
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'reload',
                child: Text('Reopen current video')),
            if (widget.legacyBuilder != null)
              const PopupMenuItem(value: 'legacy',
                  child: Text('Compare legacy MPV player')),
          ],
        ),
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hasFile = _path != null;
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: !hasFile && !_fullScreen
            ? AppBar(title: const Text('Droid Vid Player'),
                actions: [
                  IconButton(onPressed: () => unawaited(openFiles()),
                    icon: const Icon(Icons.folder_open),
                    tooltip: 'Open videos'),
                  if (widget.legacyBuilder != null)
                    IconButton(onPressed: () => unawaited(_openLegacy()),
                      tooltip: 'Legacy MPV comparison',
                      icon: const Icon(Icons.compare_arrows)),
                ])
            : null,
        body: hasFile ? Stack(fit: StackFit.expand, children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_ready && _video != null)
            _videoSurface(_video!)
          else
            Center(child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(_error ?? 'Video could not be opened.',
                textAlign: TextAlign.center))),
          if (_reverseActive && _reverseImage != null)
            Positioned.fill(child: IgnorePointer(child: Center(
              child: Image.memory(_reverseImage!, fit: BoxFit.contain,
                gaplessPlayback: true),
            ))),
          if (_reverseActive && _reverseLoading)
            const Positioned(top: 115, left: 12, right: 12,
              child: Center(child: Text('Buffering reverse frames…'))),
          if ((_scrubbing && _swipeScrub) ||
              (_swipeActive && _swipeMode == _SwipeMode.forward))
            Positioned(top: 76, left: 8, right: 8, child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _swipeMode == _SwipeMode.forward
                        ? 'Requested ${_forwardSpeed.toStringAsFixed(0)}× · actual ${_observedSpeed?.toStringAsFixed(1) ?? 'measuring'}×  ${_clock(_position)}'
                        : '${_lastSwipeDx >= 0 ? '▶' : '◀'} Preview  ${_clock(_scrubAt)}',
                    style: const TextStyle(fontSize: 20)),
                ),
              ),
            )),
          if (_slowHolding)
            const Positioned(top: 76, left: 0, right: 0,
              child: Center(child: Text('Slow motion 0.5× · Release to resume'))),
          if (_controlsVisible && !_scrubbing) Positioned(
              top: 0, left: 0, right: 0, child: _toolbar()),
          if ((_controlsVisible || _scrubbing) && _ready)
            Positioned(left: 0, right: 0, bottom: 0,
                child: _overlayControls()),
          if (!_loading && !_ready)
            Positioned(left: 12, right: 12, bottom: 32, child: Column(
              mainAxisSize: MainAxisSize.min, children: [
                FilledButton.icon(
                  onPressed: () => unawaited(_openRecovery()),
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Recover & Record')),
                OutlinedButton.icon(
                  onPressed: () => unawaited(openFiles()),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose another video')),
                if (widget.legacyBuilder != null)
                  TextButton.icon(
                    onPressed: () => unawaited(_openLegacy()),
                    icon: const Icon(Icons.compare_arrows),
                    label: const Text('Try legacy MPV decoder')),
              ],
            )),
          if (_error != null && _ready)
            Positioned(left: 12, right: 12, top: 70, child: Material(
              color: Colors.red.shade900,
              borderRadius: BorderRadius.circular(8),
              child: Row(children: [
                Expanded(child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_error!, maxLines: 3))),
                IconButton(onPressed: () => setState(() => _error = null),
                    icon: const Icon(Icons.close)),
              ]),
            )),
        ]) : Center(child: Column(
          mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.video_library_outlined, size: 60),
            const SizedBox(height: 16),
            const Text('Droid Vid Player', style: TextStyle(
                fontSize: 23, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Android playback powered by ExoPlayer'),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => unawaited(openFiles()),
              icon: const Icon(Icons.folder_open),
              label: const Text('Open local videos')),
            if (_error != null) Padding(
              padding: const EdgeInsets.all(16), child: Text(_error!,
                style: const TextStyle(color: Colors.orangeAccent))),
          ],
        )),
      ),
    );
  }
}
