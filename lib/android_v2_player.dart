import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import 'guided_recovery_screen.dart';

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
  double _totalDrag = 0;
  double _gestureWidth = 400;

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

  Future<void> _openHardwarePreview(int generation) async {
    final source = _source;
    if (source == null || _previewOpening || !_previewAvailable) return;
    _previewOpening = true;
    try {
      final response = await _hardware.invokeMapMethod<String, dynamic>(
        'open', <String, Object>{'path': source});
      if (!mounted || generation != _previewGeneration ||
          !_scrubbing || !_scrubOnPicture) {
        unawaited(_hardware.invokeMethod<void>('close'));
        return;
      }
      if (response != null) {
        setState(() {
          _previewTexture = (response['textureId'] as num).toInt();
          _previewSession = (response['session'] as num).toInt();
        });
        _requestHardwareFrame();
      }
    } catch (_) {
      _previewAvailable = false;
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
    ++_slowGeneration;
    _hideTimer?.cancel();
    final old = _video;
    _previewGeneration++;
    _previewAvailable = true;
    _previewTexture = null;
    _previewSession = null;
    _previewFrameReady = false;
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
    if (!_ready || _scrubbing || _finishingScrub) {
      return;
    }
    final ms = (_position.inMilliseconds + seconds * 1000)
        .clamp(0, _duration.inMilliseconds);
    try {
      await _video!.seekTo(Duration(milliseconds: ms));
      _showControls();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Seek failed: $e');
      }
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
    ++_scrubGeneration;
    _gestureWidth = width;
    _totalDrag = 0;
    _scrubStart = _position;
    _scrubTarget = _scrubStart;
    _resumeAfterScrub = previouslyPlaying;
    _pauseTask = previouslyPlaying ? _video!.pause() : Future<void>.value();
    _pendingSeek = null;
    _hideTimer?.cancel();
    if (picture && _previewAvailable) {
      unawaited(_openHardwarePreview(++_previewGeneration));
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
    if (_scrubOnPicture && _previewAvailable) {
      _requestHardwareFrame();
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

  void _pictureDragStart(DragStartDetails details, double width) {
    _beginScrub(picture: true, width: width);
  }

  void _pictureDragUpdate(DragUpdateDetails details) {
    if (!_scrubbing || !_scrubOnPicture) {
      return;
    }
    _totalDrag += details.delta.dx;
    final newMs = _scrubStart.inMilliseconds +
        (_totalDrag * _msPerPixel()).round();
    _moveScrub(Duration(milliseconds: newMs));
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
          if (wasPictureGesture) _closeHardwarePreview();
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
      await player!.setPlaybackSpeed(0.5);
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
    try {
      await _video?.pause();
      if (!mounted) {
        return;
      }
      final recovered = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => GuidedRecoveryScreen(sourcePath: source),
        ),
      );
      if (!mounted) {
        return;
      }
      if (recovered != null && await File(recovered).exists()) {
        _files..clear()..add(recovered);
        _index = 0;
        await _openFile();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Recovery failed: $e');
      }
    }
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
        onHorizontalDragStart: (details) =>
            _pictureDragStart(details, constraints.maxWidth),
        onHorizontalDragUpdate: _pictureDragUpdate,
        onHorizontalDragEnd: (_) => unawaited(_finishScrub()),
        onHorizontalDragCancel: () => unawaited(_finishScrub()),
        onLongPressStart: _startSlow,
        onLongPressEnd: (_) => unawaited(_stopSlow()),
        onLongPressCancel: () => unawaited(_stopSlow()),
        child: SizedBox.expand(
          child: ClipRect(
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
      );
    },
  );

  Widget _scrubOverlay() => IgnorePointer(
    child: Align(
      alignment: const Alignment(0, -0.15),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_clock(_scrubTarget), style: const TextStyle(
              fontSize: 32, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(_relativeTime(_scrubTarget - _scrubStart),
              style: const TextStyle(
                fontSize: 18, color: Colors.white70)),
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
              } else if (action == 'legacy') {
                unawaited(_compare());
              }
            },
            itemBuilder: (_) => [
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
            child: Center(child: Text('Slow motion 0.5×'))),
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
