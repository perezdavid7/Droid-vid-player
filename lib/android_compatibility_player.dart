import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as p;

/// Alternate Android playback backend. Does not change video data.
class AndroidCompatibilityPlayer extends StatefulWidget {
  final String sourcePath;
  const AndroidCompatibilityPlayer({super.key, required this.sourcePath});

  @override
  State<AndroidCompatibilityPlayer> createState() =>
      _AndroidCompatibilityPlayerState();
}

class _AndroidCompatibilityPlayerState
    extends State<AndroidCompatibilityPlayer> {
  late final VideoPlayerController _video;
  bool _ready = false;
  bool _loading = true;
  String? _error;
  bool _seeking = false;
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    _video = VideoPlayerController.file(File(widget.sourcePath));
    _video.addListener(_onVideoChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _video.initialize();
      if (!mounted) return;
      setState(() {
        _ready = true;
        _loading = false;
      });
      await _video.play();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Android compatibility playback failed: $e';
        _loading = false;
      });
    }
  }

  void _onVideoChanged() {
    if (mounted && _ready) {
      setState(() {});
    }
  }

  Future<void> _seek(Duration target) async {
    if (_seeking || !_ready) {
      return;
    }
    setState(() => _seeking = true);
    try {
      await _video.seekTo(target).timeout(const Duration(seconds: 8));
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'This video did not seek reliably: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _seeking = false);
      }
    }
  }

  String _time(Duration value) {
    final hours = value.inHours;
    final min = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$min:$sec' : '$min:$sec';
  }

  @override
  void dispose() {
    _video.removeListener(_onVideoChanged);
    unawaited(_video.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _ready ? _video.value.duration : Duration.zero;
    final position = _ready ? _video.value.position : Duration.zero;
    final maxMs = total.inMilliseconds.toDouble();
    final ms = (_dragValue ?? position.inMilliseconds.toDouble())
        .clamp(0.0, maxMs > 0 ? maxMs : 1.0);
    return Scaffold(
      appBar: AppBar(title: const Text('Android Compatibility Player')),
      backgroundColor: Colors.black,
      body: SafeArea(child: Column(children: [
        Expanded(child: Center(child: _loading
            ? const CircularProgressIndicator()
            : _ready && _video.value.aspectRatio > 0
                ? AspectRatio(
                    aspectRatio: _video.value.aspectRatio,
                    child: VideoPlayer(_video))
                : Text(_error ?? 'Video unavailable'))),
        if (_error != null && _ready)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: const TextStyle(
                color: Colors.orangeAccent))),
        if (_ready) ...[
          Row(children: [
            const SizedBox(width: 8),
            Text(_time(position)),
            Expanded(child: Slider(
              value: ms,
              min: 0,
              max: maxMs > 0 ? maxMs : 1,
              onChanged: maxMs <= 0 || _seeking ? null
                  : (value) => setState(() => _dragValue = value),
              onChangeEnd: maxMs <= 0 || _seeking ? null
                  : (value) {
                      setState(() => _dragValue = null);
                      unawaited(_seek(
                          Duration(milliseconds: value.round())));
                    },
            )),
            Text(_time(total)),
            const SizedBox(width: 8),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
              tooltip: 'Back 10 seconds',
              onPressed: _seeking ? null : () => unawaited(_seek(
                Duration(milliseconds:
                  (position.inMilliseconds - 10000)
                      .clamp(0, total.inMilliseconds)))),
              icon: const Icon(Icons.replay_10)),
            IconButton.filled(
              onPressed: () => unawaited(_video.value.isPlaying
                  ? _video.pause() : _video.play()),
              icon: Icon(_video.value.isPlaying
                  ? Icons.pause : Icons.play_arrow)),
            IconButton(
              tooltip: 'Forward 10 seconds',
              onPressed: _seeking ? null : () => unawaited(_seek(
                Duration(milliseconds:
                  (position.inMilliseconds + 10000)
                      .clamp(0, total.inMilliseconds)))),
              icon: const Icon(Icons.forward_10)),
          ]),
        ],
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text('File: ${p.basename(widget.sourcePath)}\n'
              'Alternative Android decoder; original and recovered '
              'files are unchanged.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
      ])),
    );
  }
}
