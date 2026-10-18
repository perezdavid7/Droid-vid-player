import 'dart:async';
import 'dart:io';
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
    _playingSubscription = player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() {
        _isPlaying = playing;
        if (!playing) _showControls = true;
      });
      _scheduleAutoHide();
    });
  }

  void _scheduleAutoHide() {
    _hideTimer?.cancel();
    if (!_isPlaying || !_showControls || _scrubbing || files.isEmpty) {
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
    '.mts', '.m2ts', '.flv', '.3gp', '.vob'
  };

  @override
  void dispose() {
    _hideTimer?.cancel();
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

  Future<void> load(List<String> paths, {int start = 0}) async {
    setState(() {
      files..clear()..addAll(paths);
      error = null;
      _showControls = true;
    });
    _resetZoom(wakeControls: false);
    await player.open(Playlist(
      paths.map((path) => Media(Uri.file(path).toString())).toList(),
      index: start < 0 ? 0 : start,
    ));
  }

  Future<void> jump(int seconds) async {
    final state = player.state;
    final ms = (state.position.inMilliseconds + seconds * 1000)
        .clamp(0, state.duration.inMilliseconds);
    await player.seek(Duration(milliseconds: ms));
  }

  String clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Widget _seekBar() => StreamBuilder<Duration>(
    stream: player.stream.position,
    initialData: Duration.zero,
    builder: (context, positionSnapshot) {
      final position = positionSnapshot.data ?? Duration.zero;
      return StreamBuilder<Duration>(
        stream: player.stream.duration,
        initialData: Duration.zero,
        builder: (context, lengthSnapshot) {
          final length = lengthSnapshot.data ?? Duration.zero;
          final max = length.inMilliseconds > 0
              ? length.inMilliseconds.toDouble()
              : 1.0;
          return Row(
            children: [
              Text(clock(position), style: const TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: position.inMilliseconds
                      .clamp(0, max.toInt())
                      .toDouble(),
                  max: max,
                  onChangeStart: (_) {
                    _scrubbing = true;
                    _hideTimer?.cancel();
                  },
                  onChanged: (files.isEmpty)
                      ? null
                      : (value) => player.seek(
                          Duration(milliseconds: value.toInt()),
                        ),
                  onChangeEnd: (_) {
                    _scrubbing = false;
                    _scheduleAutoHide();
                  },
                ),
              ),
              Text(clock(length), style: const TextStyle(fontSize: 12)),
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
        onPressed: files.isEmpty ? null : () {
          _wakeControls();
          jump(-10);
        },
        icon: const Icon(Icons.replay_10),
      ),
      IconButton.filled(
        tooltip: _isPlaying ? 'Pause' : 'Play',
        onPressed: files.isEmpty ? null : () {
          _wakeControls();
          player.playOrPause();
        },
        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
      ),
      IconButton(
        tooltip: 'Forward 10 seconds',
        onPressed: files.isEmpty ? null : () {
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
