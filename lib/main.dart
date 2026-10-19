import 'dart:async';
import 'dart:io';
import 'recovery_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const DroidVidPlayer());
}

class DroidVidPlayer extends StatelessWidget {
  const DroidVidPlayer({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Droid Vid Player',
    theme: ThemeData.dark(useMaterial3: true),
    home: const PlayerScreen(),
  );
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player player = Player();
  late final VideoController video = VideoController(player);
  final files = <String>[];
  double speed = 1;
  bool fill = false;
  int turns = 0;
  String? error;
  bool _isPlaying = false;
  bool _showControls = true;
  bool _fullScreen = false;
  bool _scrubbing = false;
  Timer? _hideTimer;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<String>? _errorSubscription;

  PlaylistMode _repeatMode = PlaylistMode.none;
  bool _ended = false;
  bool _unreliableDuration = false;
  Duration? _lastPosition;
  int _lastPlaylistIndex = -1;
  DateTime _ignorePositionBackstepsUntil = DateTime.fromMillisecondsSinceEpoch(0);

  Duration? _scrubPosition;
  int _scrubGeneration = 0;
  bool _resumeAfterScrub = false;
  bool _seekInProgress = false;
  bool _shuttling = false;
  bool _shuttleWasPlaying = false;
  bool _shuttleRateApplied = false;
  bool _reverseUnavailable = false;
  int _shuttleGeneration = 0;
  int _shuttleDirection = 0;
  int _appliedShuttleDirection = 1;
  int _requestedShuttleDirection = 0;
  double _shuttleRate = 1.0;
  double _appliedShuttleRate = 1.0;
  double _requestedShuttleRate = 1.0;
  double _shuttleOriginalVolume = 100.0;
  bool _shuttleMuted = false;
  double _shuttleTravel = 0.0;
  DateTime? _lastSwipeUpdate;
  Future<void>? _shuttleTask;
  String? _shuttleWarning;
  Timer? _liveScrubTimer;
  Future<void>? _liveScrubTask;
  Future<void>? _scrubPauseTask;
  Duration? _pendingLiveScrubTarget;
  bool _liveScrubFailed = false;
  DateTime _lastLiveScrubSeek = DateTime.fromMillisecondsSinceEpoch(0);
  static const _liveScrubInterval = Duration(milliseconds: 220);



  // One transform for the full video viewport; gestures and buttons share it.
  final TransformationController _zoomController = TransformationController();
  double _zoom = 1.0;
  Size _videoViewport = Size.zero;
  Offset _doubleTapPosition = Offset.zero;

  static const double _maxZoom = 6.0;

  void _onZoomChanged() {
    final value = _zoomController.value.getMaxScaleOnAxis();
    if (mounted && (_zoom - value).abs() > 0.01) {
      setState(() => _zoom = value);
    }
  }

  void _resetZoom({bool wakeControls = true}) {
    _zoomController.value = Matrix4.identity();
    if (wakeControls) _wakeControls();
  }

  // Retain the chosen point under the finger while changing scale.
  void _setZoom(double requested, Offset focalPoint) {
    if (_videoViewport.isEmpty) return;
    final target = requested.clamp(1.0, _maxZoom);
    if (target <= 1.001) {
      _resetZoom();
      return;
    }

    final scenePoint = _zoomController.toScene(focalPoint);
    final dx = (focalPoint.dx - target * scenePoint.dx)
        .clamp(_videoViewport.width * (1 - target), 0.0);
    final dy = (focalPoint.dy - target * scenePoint.dy)
        .clamp(_videoViewport.height * (1 - target), 0.0);
    _zoomController.value = Matrix4.identity()
      ..setEntry(0, 0, target)
      ..setEntry(1, 1, target)
      ..setEntry(0, 3, dx)
      ..setEntry(1, 3, dy);
    _wakeControls();
  }

  void _zoomBy(double factor) {
    final center = Offset(_videoViewport.width / 2, _videoViewport.height / 2);
    _setZoom(_zoom * factor, center);
  }

  void _doubleTapZoom() {
    if (_zoom > 1.05) {
      _resetZoom();
    } else {
      _setZoom(2.5, _doubleTapPosition);
    }
  }

  @override
  void initState() {
    super.initState();
    _zoomController.addListener(_onZoomChanged);
    _completedSubscription = player.stream.completed.listen((completed) {
      if (!mounted) return;
      setState(() {
        _ended = completed;
        if (completed && !_shuttling) _showControls = true;
      });
      if (completed) _hideTimer?.cancel();
    });
    _positionSubscription = player.stream.position.listen((position) {
      if (!mounted || _scrubbing) return;
      if (_shuttling) {
        // Reverse playback deliberately runs timestamps backward.
        _lastPosition = position;
        return;
      }
      final state = player.state;
      final index = state.playlist.index;
      if (index != _lastPlaylistIndex) {
        _lastPlaylistIndex = index;
        _lastPosition = null;
        if (_unreliableDuration) setState(() => _unreliableDuration = false);
      }
      final duration = state.duration;
      final beyond = duration > Duration.zero &&
          position > duration + const Duration(seconds: 1);
      // Some malformed files jump their presentation timestamp backwards
      // even though playback continues: do not portray that as a completed file.
      final jumpedBack = _lastPosition != null &&
          _lastPosition! - position > const Duration(seconds: 3) &&
          state.playing && !state.completed &&
          DateTime.now().isAfter(_ignorePositionBackstepsUntil) &&
          _repeatMode == PlaylistMode.none;
      if ((beyond || jumpedBack) && !_unreliableDuration) {
        setState(() => _unreliableDuration = true);
      }
      _lastPosition = position;
    });
    _errorSubscription = player.stream.error.listen((message) {
      if (!mounted || files.isEmpty) return;
      final index = player.state.playlist.index.clamp(0, files.length - 1);
      final extension = p.extension(files[index]).toLowerCase();
      setState(() => error = 'Cannot decode this $extension video: $message. '
          'You can try Recover & Record on this file.');
    });
    _playingSubscription = player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() {
        _isPlaying = playing;
        if (!playing && !_shuttling) _showControls = true;
      });
      _scheduleAutoHide();
    });
  }

  void _scheduleAutoHide() {
    _hideTimer?.cancel();
    if (!_isPlaying || !_showControls || _scrubbing ||
        _shuttling || files.isEmpty) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isPlaying && !_scrubbing) {
        setState(() => _showControls = false);
      }
    });
  }

  void _wakeControls() {
    if (!_showControls) {
      setState(() => _showControls = true);
    }
    _scheduleAutoHide();
  }

  void _tapVideo() {
    if (!_showControls) {
      _wakeControls();
    } else if (_isPlaying) {
      _hideTimer?.cancel();
      setState(() => _showControls = false);
    }
  }

  Future<void> _toggleFullScreen() async {
    final next = !_fullScreen;
    try {
      await SystemChrome.setEnabledSystemUIMode(
        next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    } catch (_) {
      // A desktop host can ignore Android-specific system UI modes.
    }
    if (!mounted) return;
    setState(() {
      _fullScreen = next;
      _showControls = true;
    });
    _scheduleAutoHide();
  }

  Future<void> _changeSpeed(double value) async {
    try {
      await player.setRate(value);
      if (!mounted) return;
      setState(() => speed = value);
      _wakeControls();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to set ${value}x speed: $e')),
      );
    }
  }


  static const extensions = <String>{
    '.mpg', '.mpeg', '.m2v', '.mkv', '.mov', '.mp4',
    '.m4v', '.avi', '.wmv', '.asf', '.webm', '.ts',
    '.mts', '.m2ts', '.flv', '.3gp', '.vob', '.vid', '.divx'
  };

  @override
  void dispose() {
    _hideTimer?.cancel();
    _cancelLiveScrubQueue();
    _shuttleGeneration++;
    _scrubGeneration++;
    _positionSubscription?.cancel();
    _completedSubscription?.cancel();
    _errorSubscription?.cancel();
    _playingSubscription?.cancel();
    _zoomController.removeListener(_onZoomChanged);
    _zoomController.dispose();
    if (_fullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    player.dispose();
    super.dispose();
  }

  Future<void> openFiles() async {
    try {
      final results = await FilePicker.pickFiles(type: FileType.any);
      final selected = results
          .map((file) => file.path)
          .whereType<String>()
          .where((file) => extensions.contains(p.extension(file).toLowerCase()))
          .toList();
      if (selected.isEmpty) return;
      if (!Platform.isAndroid && selected.length == 1) {
        final entries = await Directory(p.dirname(selected.first))
            .list()
            .where((entity) => entity is File && extensions.contains(p.extension(entity.path).toLowerCase()))
            .map((entity) => entity.path)
            .toList();
        entries.sort();
        if (entries.isNotEmpty) {
          await load(entries, start: entries.indexOf(selected.first));
          return;
        }
      }
      await load(selected);
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  Future<void> _openRecovery() async {
    if (files.isEmpty) return;
    final index = player.state.playlist.index.clamp(0, files.length - 1);
    final source = files[index];
    try {
      // Pause regular playback while the separate decoder is working.
      await player.pause();
      if (!mounted) return;
      final recovered = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => RecoveryScreen(sourcePath: source),
        ),
      );
      if (!mounted) return;
      if (recovered != null && await File(recovered).exists()) {
        // Playback can now seek on the new recovered file. The original
        // remains where it was and can be reopened at any time.
        await load([recovered]);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => error = 'Unable to open recovery: $e');
    }
  }

  Future<void> load(List<String> paths, {int start = 0}) async {
    setState(() {
      files..clear()..addAll(paths);
      error = null;
      _showControls = true;
      _ended = false;
      _unreliableDuration = false;
      _lastPosition = null;
      _scrubPosition = null;
      _scrubbing = false;
      _seekInProgress = false;
      _lastPlaylistIndex = start < 0 ? 0 : start;
    });
    _cancelLiveScrubQueue();
    _scrubGeneration++;
    _resetZoom(wakeControls: false);
    await player.open(Playlist(
      paths.map((path) => Media(Uri.file(path).toString())).toList(),
      index: start < 0 ? 0 : start,
    ));
    await player.setPlaylistMode(_repeatMode);
  }

  Future<void> jump(int seconds) async {
    // Repeated seeking on broken timestamps may restart playback or hang mpv.
    if (_seekInProgress || _unreliableDuration) return;
    final state = player.state;
    final ms = (state.position.inMilliseconds + seconds * 1000)
        .clamp(0, state.duration.inMilliseconds);
    _ignorePositionBackstepsUntil =
        DateTime.now().add(const Duration(seconds: 2));
    await player.seek(Duration(milliseconds: ms));
  }

  Future<void> _restartCurrent() async {
    if (files.isEmpty) return;
    final originalIndex = player.state.playlist.index;
    final index = originalIndex.clamp(0, files.length - 1);
    _cancelLiveScrubQueue();
    _scrubGeneration++;
    setState(() {
      _ended = false;
      _unreliableDuration = false;
      _lastPosition = null;
      _lastPlaylistIndex = index;
      _scrubbing = false;
      _scrubPosition = null;
      _seekInProgress = false;
    });
    _ignorePositionBackstepsUntil =
        DateTime.now().add(const Duration(seconds: 3));
    // Re-open to reset demuxer/decoder state. Merely seeking to 00:00
    // can leave some damaged media stuttering after an EOF.
    await player.open(Playlist(
      files.map((path) => Media(Uri.file(path).toString())).toList(),
      index: index,
    ));
    await player.setPlaylistMode(_repeatMode);
    await player.setRate(speed);
    _wakeControls();
  }

  Future<void> _playPause() async {
    if (_ended || player.state.completed) {
      await _restartCurrent();
    } else {
      await player.playOrPause();
    }
  }

  Future<void> _cycleRepeat() async {
    final next = switch (_repeatMode) {
      PlaylistMode.none => PlaylistMode.single,
      PlaylistMode.single => PlaylistMode.loop,
      PlaylistMode.loop => PlaylistMode.none,
    };
    await player.setPlaylistMode(next);
    if (!mounted) return;
    setState(() => _repeatMode = next);
    _wakeControls();
  }


  String clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }



  // Live scrubbing previews *actual* frames on the video, rather than a
  // separate JPEG screenshot. Native seeks are serialized and rate limited.
  // The latest position wins: no huge decoder seek queue can build up.
  void _cancelLiveScrubQueue() {
    _liveScrubTimer?.cancel();
    _liveScrubTimer = null;
    _pendingLiveScrubTarget = null;
  }

  Future<void> _pauseForScrub(int generation) async {
    try {
      await player.pause().timeout(const Duration(seconds: 3));
    } catch (_) {
      if (generation == _scrubGeneration) _liveScrubFailed = true;
    }
  }

  void _beginScrub(double v) {
    if (_seekInProgress || _unreliableDuration || _scrubbing) return;
    final generation = ++_scrubGeneration;
    _cancelLiveScrubQueue();
    _liveScrubFailed = false;
    _lastLiveScrubSeek = DateTime.now().subtract(_liveScrubInterval);
    _resumeAfterScrub = player.state.playing;
    setState(() {
      _scrubbing = true;
      _scrubPosition = Duration(milliseconds: v.round());
      _showControls = true;
    });
    _hideTimer?.cancel();
    _scrubPauseTask = _pauseForScrub(generation);
  }

  void _updateScrub(double v) {
    if (!_scrubbing || _seekInProgress) return;
    final target = Duration(milliseconds: v.round());
    setState(() => _scrubPosition = target);
    if (!_liveScrubFailed) {
      _pendingLiveScrubTarget = target;
      _scheduleLiveScrub();
    }
  }

  void _scheduleLiveScrub() {
    if (!_scrubbing || _seekInProgress || _liveScrubFailed ||
        _liveScrubTimer != null || _liveScrubTask != null ||
        _pendingLiveScrubTarget == null) {
      return;
    }
    final elapsed = DateTime.now().difference(_lastLiveScrubSeek);
    final remaining = _liveScrubInterval - elapsed;
    _liveScrubTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        _liveScrubTimer = null;
        if (!_scrubbing || _seekInProgress || _liveScrubFailed ||
            _liveScrubTask != null) {
          return;
        }
        final target = _pendingLiveScrubTarget;
        if (target == null) return;
        _pendingLiveScrubTarget = null;
        _lastLiveScrubSeek = DateTime.now();
        _liveScrubTask = _previewLiveScrub(target, _scrubGeneration);
      },
    );
  }

  Future<void> _previewLiveScrub(Duration target, int generation) async {
    try {
      await _scrubPauseTask;
      if (!mounted || generation != _scrubGeneration ||
          _liveScrubFailed || !_scrubbing) {
        return;
      }
      _ignorePositionBackstepsUntil =
          DateTime.now().add(const Duration(seconds: 5));
      // A seek on the paused video renders the decoded frame itself. Never
      // request screenshots or start another seek before this one finishes.
      await player.seek(target).timeout(const Duration(seconds: 3));
    } catch (_) {
      // A malformed recording may not support seeking. Stop preview requests,
      // retaining the ability to use forward-only Recover & Record.
      if (generation == _scrubGeneration) _liveScrubFailed = true;
    } finally {
      _liveScrubTask = null;
      if (mounted && generation == _scrubGeneration) {
        _scheduleLiveScrub();
      }
    }
  }


  // Shuttle mode plays actual frames at a variable playback rate rather than
  // displaying isolated seek positions. Reverse is experimental in libmpv.
  void _beginVideoSwipe(DragStartDetails details) {
    if (files.isEmpty || _seekInProgress || _unreliableDuration ||
        _scrubbing || _shuttling || player.state.duration <= Duration.zero) {
      return;
    }
    _shuttleGeneration++;
    _shuttleWasPlaying = player.state.playing;
    _shuttleOriginalVolume = player.state.volume;
    _shuttleMuted = false;
    _shuttleRateApplied = false;
    _reverseUnavailable = false;
    _shuttleDirection = 0;
    _appliedShuttleDirection = 1;
    _requestedShuttleDirection = 0;
    _appliedShuttleRate = speed;
    _requestedShuttleRate = speed;
    _shuttleRate = speed;
    _shuttleTravel = 0.0;
    _lastSwipeUpdate = DateTime.now();
    _hideTimer?.cancel();
    setState(() {
      _shuttling = true;
      _showControls = false;
      _shuttleWarning = null;
    });
  }

  void _updateVideoSwipe(DragUpdateDetails details) {
    if (!_shuttling || _lastSwipeUpdate == null) return;
    final now = DateTime.now();
    final dt = now.difference(_lastSwipeUpdate!).inMicroseconds / 1000000.0;
    _lastSwipeUpdate = now;
    final dx = details.delta.dx;
    _shuttleTravel += dx;
    if (_shuttleTravel.abs() < 1.8) return;
    final direction = _shuttleTravel > 0 ? 1 : -1;
    _shuttleTravel = 0.0;
    // Slow thumb motion advances frames gently; rapid movement increases the
    // actual forward/reverse playback speed while the finger is held down.
    final pixelsPerSecond = dx.abs() / dt.clamp(0.012, 0.25);
    final rate = (0.35 + pixelsPerSecond / 150.0).clamp(0.35, 5.0).toDouble();
    if (_reverseUnavailable && direction < 0) {
      setState(() => _shuttleWarning =
          'Reverse playback unavailable for this video');
      return;
    }
    setState(() {
      _shuttleDirection = direction;
      _shuttleRate = rate;
      _shuttleWarning = null;
    });
    _requestedShuttleDirection = direction;
    _requestedShuttleRate = rate;
    _queueShuttleUpdate(_shuttleGeneration);
  }

  void _queueShuttleUpdate(int generation) {
    if (_shuttleTask != null || !_shuttling) return;
    _shuttleTask = _applyShuttle(generation).whenComplete(() {
      _shuttleTask = null;
      if (mounted && _shuttling && generation == _shuttleGeneration &&
          _requestedShuttleDirection != 0 &&
          (_requestedShuttleDirection != _appliedShuttleDirection ||
           (_requestedShuttleRate - _appliedShuttleRate).abs() > 0.20)) {
        _queueShuttleUpdate(generation);
      }
    });
  }

  Future<void> _applyShuttle(int generation) async {
    try {
      while (mounted && _shuttling && generation == _shuttleGeneration) {
        final direction = _requestedShuttleDirection;
        final rate = _requestedShuttleRate;
        if (direction == 0) return;
        final native = player.platform;
        if (direction != _appliedShuttleDirection) {
          if (native is! NativePlayer) {
            throw UnsupportedError('Reverse shuttle requires native playback');
          }
          await native.setProperty(
            'play-direction', direction < 0 ? 'backward' : 'forward',
          ).timeout(const Duration(seconds: 3));
          _appliedShuttleDirection = direction;
        }
        if (!_shuttleMuted) {
          await player.setVolume(0).timeout(const Duration(seconds: 3));
          _shuttleMuted = true;
        }
        if (!_shuttleRateApplied || (rate - _appliedShuttleRate).abs() > 0.20) {
          await player.setRate(rate).timeout(const Duration(seconds: 3));
          _appliedShuttleRate = rate;
          _shuttleRateApplied = true;
        }
        if (!player.state.playing) {
          await player.play().timeout(const Duration(seconds: 3));
        }
        if (generation != _shuttleGeneration ||
            !_shuttling ||
            (_requestedShuttleDirection == _appliedShuttleDirection &&
             (_requestedShuttleRate - _appliedShuttleRate).abs() <= 0.20)) {
          break;
        }
      }
    } catch (_) {
      if (!mounted || generation != _shuttleGeneration) return;
      if (_requestedShuttleDirection < 0) _reverseUnavailable = true;
      _requestedShuttleDirection = 0;
      setState(() => _shuttleWarning =
          'Shuttle unsupported for this file; lift your finger');
    }
  }

  void _endVideoSwipe(DragEndDetails details) {
    if (!_shuttling) return;
    _lastSwipeUpdate = null;
    unawaited(_finishVideoShuttle());
  }

  Future<void> _finishVideoShuttle() async {
    if (!_shuttling) return;
    final generation = _shuttleGeneration;
    _requestedShuttleDirection = 0;
    try {
      await _shuttleTask?.timeout(const Duration(seconds: 4));
      final native = player.platform;
      if (native is NativePlayer) {
        await native.setProperty('play-direction', 'forward')
            .timeout(const Duration(seconds: 4));
      }
      await player.setRate(speed).timeout(const Duration(seconds: 4));
      if (_shuttleMuted) {
        await player.setVolume(_shuttleOriginalVolume)
            .timeout(const Duration(seconds: 4));
      }
      if (_shuttleWasPlaying) {
        await player.play().timeout(const Duration(seconds: 4));
      } else {
        await player.pause().timeout(const Duration(seconds: 4));
      }
    } catch (_) {
      if (mounted && generation == _shuttleGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(
            'This video could not shuttle smoothly. Try a recovered copy.',
          )),
        );
      }
    } finally {
      if (mounted && generation == _shuttleGeneration) {
        setState(() {
          _shuttling = false;
          _showControls = true;
          _shuttleWarning = null;
          _shuttleDirection = 0;
        });
        _scheduleAutoHide();
      }
    }
  }

  Future<void> _endScrub(double v) async {
    if (!_scrubbing || _seekInProgress) return;
    final generation = _scrubGeneration;
    final resume = _resumeAfterScrub;
    final target = Duration(milliseconds: v.round());
    _cancelLiveScrubQueue();
    setState(() => _seekInProgress = true);

    try {
      // Complete the in-flight preview *before* the final precise seek.
      // A timeout never causes a second native seek to be queued.
      await _liveScrubTask?.timeout(const Duration(seconds: 4));
      await _scrubPauseTask?.timeout(const Duration(seconds: 4));
      if (_liveScrubFailed) {
        throw TimeoutException('Live preview could not seek this file');
      }
      if (!mounted || generation != _scrubGeneration) return;
      _ignorePositionBackstepsUntil =
          DateTime.now().add(const Duration(seconds: 5));
      await player.seek(target).timeout(const Duration(seconds: 5));
      if (!mounted || generation != _scrubGeneration) return;
      if (resume) {
        await player.play().timeout(const Duration(seconds: 5));
      }
    } on TimeoutException {
      if (mounted && generation == _scrubGeneration) {
        setState(() => _unreliableDuration = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(
            'This video cannot scrub reliably. Seeking has been disabled; '
            'try Recover & Record to create a seekable copy.',
          )),
        );
      }
    } catch (e) {
      if (mounted && generation == _scrubGeneration) {
        setState(() => _unreliableDuration = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scrubbing failed: $e')),
        );
      }
    } finally {
      if (mounted && generation == _scrubGeneration) {
        setState(() {
          _scrubbing = false;
          _scrubPosition = null;
          _seekInProgress = false;
        });
        _scheduleAutoHide();
      }
    }
  }

  Widget _seekBar() => StreamBuilder<Duration>(
    stream: player.stream.position,
    initialData: player.state.position,
    builder: (context, positionSnapshot) {
      final position = positionSnapshot.data ?? player.state.position;
      return StreamBuilder<Duration>(
        stream: player.stream.duration,
        initialData: player.state.duration,
        builder: (context, durationSnapshot) {
          final length = durationSnapshot.data ?? player.state.duration;
          final valid = length > Duration.zero &&
              !_unreliableDuration &&
              position <= length + const Duration(seconds: 1);
          final max = valid ? length.inMilliseconds.toDouble() : 1.0;
          final displayed = _scrubbing
              ? (_scrubPosition ?? position)
              : position;
          final value = valid
              ? displayed.inMilliseconds.clamp(0, max.toInt()).toDouble()
              : 0.0;
          final canSeek = valid && !_seekInProgress && !_liveScrubFailed;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_scrubbing)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.touch_app, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text('Scrubbing ${clock(displayed)} · release to play',
                            style: const TextStyle(fontSize: 14),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
              if (_seekInProgress)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'Seeking to selected frame…',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              Row(
                children: [
                  Text(clock(displayed),
                      style: const TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: value,
                      max: max,
                      onChangeStart: canSeek ? _beginScrub : null,
                      onChanged: canSeek ? _updateScrub : null,
                      onChangeEnd: canSeek ? _endScrub : null,
                    ),
                  ),
                  Text(valid ? clock(length) : '--:--',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
              if (!valid && files.isNotEmpty)
                const Text(
                  'Video timestamps unreliable. Seeking is unavailable.',
                  style: TextStyle(fontSize: 11, color: Colors.amberAccent),
                  textAlign: TextAlign.center,
                ),
            ],
          );
        },
      );
    },
  );

  Widget _transportButtons() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Previous video',
        onPressed: files.isEmpty ? null : () {
          _resetZoom(wakeControls: false);
          _wakeControls();
          player.previous();
        },
        icon: const Icon(Icons.skip_previous),
      ),
      IconButton(
        tooltip: 'Back 10 seconds',
        onPressed: files.isEmpty || _unreliableDuration || _seekInProgress
            ? null
            : () {
                _wakeControls();
                jump(-10);
              },
        icon: const Icon(Icons.replay_10),
      ),
      IconButton.filled(
        tooltip: _isPlaying ? 'Pause' : 'Play',
        onPressed: files.isEmpty ? null : () {
          _wakeControls();
          _playPause();
        },
        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
      ),
      IconButton(
        tooltip: 'Forward 10 seconds',
        onPressed: files.isEmpty || _unreliableDuration || _seekInProgress
            ? null
            : () {
                _wakeControls();
                jump(10);
              },
        icon: const Icon(Icons.forward_10),
      ),
      IconButton(
        tooltip: 'Next video',
        onPressed: files.isEmpty ? null : () {
          _resetZoom(wakeControls: false);
          _wakeControls();
          player.next();
        },
        icon: const Icon(Icons.skip_next),
      ),
      IconButton(
        tooltip: 'Replay from the beginning',
        onPressed: files.isEmpty ? null : _restartCurrent,
        icon: const Icon(Icons.replay),
      ),
    ],
  );

  Widget _displayButtons() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      DropdownButton<double>(
        value: speed,
        dropdownColor: const Color(0xFF24212A),
        underline: const SizedBox.shrink(),
        items: const [0.1, 0.2, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 4.0]
            .map((value) => DropdownMenuItem<double>(
                  value: value,
                  child: Text('${value}x', style: TextStyle(fontSize: 14)),
                ))
            .toList(),
        onChanged: files.isEmpty ? null : (value) {
          if (value == null) return;
          _changeSpeed(value);
        },
      ),
      IconButton(
        tooltip: switch (_repeatMode) {
          PlaylistMode.none => 'Repeat Off',
          PlaylistMode.single => 'Repeat One',
          PlaylistMode.loop => 'Repeat All',
        },
        onPressed: files.isEmpty ? null : _cycleRepeat,
        icon: Icon(
          _repeatMode == PlaylistMode.single
              ? Icons.repeat_one
              : Icons.repeat,
          color: _repeatMode == PlaylistMode.none
              ? Colors.white70
              : Colors.tealAccent,
        ),
      ),
      IconButton(
        tooltip: 'Rotate video 90 degrees',
        onPressed: () {
          setState(() => turns = (turns + 1) % 4);
          _resetZoom();
        },
        icon: const Icon(Icons.rotate_right),
      ),
      IconButton(
        tooltip: fill ? 'Fit video' : 'Fill screen (crop to fit)',
        onPressed: () {
          setState(() => fill = !fill);
          _resetZoom();
        },
        icon: Icon(fill ? Icons.fit_screen : Icons.zoom_out_map),
      ),
      IconButton(
        tooltip: _fullScreen ? 'Exit full screen' : 'Full screen',
        onPressed: _toggleFullScreen,
        icon: Icon(_fullScreen ? Icons.fullscreen_exit : Icons.fullscreen),
      ),
    ],
  );

  Widget _zoomButtons() => Row(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        tooltip: 'Zoom out',
        onPressed: files.isEmpty || _zoom <= 1.01
            ? null
            : () => _zoomBy(1 / 1.5),
        icon: const Icon(Icons.zoom_out),
      ),
      SizedBox(
        width: 55,
        child: Text(
          '${_zoom.toStringAsFixed(1)}×',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: Colors.white),
        ),
      ),
      IconButton(
        tooltip: 'Zoom in',
        onPressed: files.isEmpty || _zoom >= _maxZoom - 0.01
            ? null
            : () => _zoomBy(1.5),
        icon: const Icon(Icons.zoom_in),
      ),
      IconButton(
        tooltip: 'Reset zoom and pan',
        onPressed: _zoom <= 1.01 ? null : _resetZoom,
        icon: const Icon(Icons.center_focus_strong),
      ),
    ],
  );

  Widget _videoWithGestures() => LayoutBuilder(
    builder: (context, constraints) {
      _videoViewport = constraints.biggest;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _tapVideo,
        onDoubleTapDown: (details) {
          _doubleTapPosition = details.localPosition;
        },
        onDoubleTap: _doubleTapZoom,
        // Use one-finger swiping for seek only at normal zoom; zoomed videos
        // retain one-finger pan and multi-touch pinch controls.
        onHorizontalDragStart: _zoom <= 1.01 ? _beginVideoSwipe : null,
        onHorizontalDragUpdate: _zoom <= 1.01 ? _updateVideoSwipe : null,
        onHorizontalDragEnd: _zoom <= 1.01 ? _endVideoSwipe : null,
        child: ClipRect(
          child: InteractiveViewer(
            transformationController: _zoomController,
            minScale: 1.0,
            maxScale: _maxZoom,
            panEnabled: _zoom > 1.01,
            scaleEnabled: true,
            boundaryMargin: EdgeInsets.zero,
            clipBehavior: Clip.hardEdge,
            onInteractionStart: (_) => _hideTimer?.cancel(),
            onInteractionEnd: (_) => _scheduleAutoHide(),
            child: SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: RotatedBox(
                quarterTurns: turns,
                child: Video(
                  controller: video,
                  fit: fill ? BoxFit.cover : BoxFit.contain,
                  controls: NoVideoControls,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _overlayToolbar() => SafeArea(
    bottom: false,
    minimum: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.50),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        const SizedBox(width: 10),
        const Expanded(
          child: Text('Droid Vid Player',
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        IconButton(
          tooltip: 'Open video',
          onPressed: () {
            _wakeControls();
            openFiles();
          },
          icon: const Icon(Icons.folder_open),
        ),
        IconButton(
          tooltip: 'Recover & Record current video',
          onPressed: _openRecovery,
          icon: const Icon(Icons.auto_fix_high),
        ),
        IconButton(
          tooltip: _fullScreen ? 'Leave full screen' : 'Full screen',
          onPressed: _toggleFullScreen,
          icon: Icon(_fullScreen ? Icons.fullscreen_exit : Icons.fullscreen),
        ),
      ]),
    ),
  );

  Widget _overlayControls(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 680;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(8, 0, 8, 24),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.70),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: Colors.white),
              child: IconTheme(
                data: const IconThemeData(color: Colors.white),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _seekBar(),
                    if (wide)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _transportButtons(),
                          _displayButtons(),
                          _zoomButtons(),
                        ],
                      )
                    else ...[
                      _transportButtons(),
                      _displayButtons(),
                      _zoomButtons(),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: _fullScreen
        ? null
        : AppBar(
            title: const Text('Droid Vid Player'),
            actions: [
              IconButton(
                onPressed: openFiles,
                tooltip: 'Open local videos',
                icon: const Icon(Icons.folder_open),
              ),
              if (files.isNotEmpty)
                IconButton(
                  tooltip: 'Recover & Record current video',
                  onPressed: _openRecovery,
                  icon: const Icon(Icons.auto_fix_high),
                ),
              IconButton(
                onPressed: _toggleFullScreen,
                tooltip: 'Full screen',
                icon: const Icon(Icons.fullscreen),
              ),
            ],
          ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: Colors.black,
          child: files.isEmpty
              ? const Center(child: Text('Open a video to begin'))
              : _videoWithGestures(),
        ),
        if (_showControls && files.isNotEmpty)
          Positioned(left: 0, top: 0, right: 0,
              child: _overlayToolbar()),
        if (_showControls && files.isNotEmpty)
          Positioned(left: 0, right: 0, bottom: 0,
              child: _overlayControls(context)),
        if (error != null)
          Positioned(
            left: 12, right: 12,
            top: _fullScreen ? 90 : 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.red.shade900,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(error!),
              ),
            ),
          ),
      ],
    ),
  );
}
