import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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

  static const extensions = <String>{
    '.mpg', '.mpeg', '.m2v', '.mkv', '.mov', '.mp4',
    '.m4v', '.avi', '.wmv', '.asf', '.webm', '.ts',
    '.mts', '.m2ts', '.flv', '.3gp', '.vob'
  };

  @override
  void dispose() {
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
    });
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

  // The controls are deliberately outside the video body. This reserves space
  // for them even on Android's edge-to-edge layouts and keeps tap targets clear
  // of the system Home / Back navigation area.
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
          return Row(children: [
            Text(clock(position), style: const TextStyle(fontSize: 12)),
            Expanded(
              child: Slider(
                value: position.inMilliseconds.clamp(0, max.toInt()).toDouble(),
                max: max,
                onChanged: files.isEmpty
                    ? null
                    : (value) => player.seek(
                        Duration(milliseconds: value.toInt()),
                      ),
              ),
            ),
            Text(clock(length), style: const TextStyle(fontSize: 12)),
          ]);
        },
      );
    },
  );

  Widget _transportControls() => Row(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      IconButton(
        tooltip: 'Previous video',
        onPressed: files.isEmpty ? null : player.previous,
        icon: const Icon(Icons.skip_previous),
      ),
      IconButton(
        tooltip: 'Back 10 seconds',
        onPressed: files.isEmpty ? null : () => jump(-10),
        icon: const Icon(Icons.replay_10),
      ),
      StreamBuilder<bool>(
        stream: player.stream.playing,
        initialData: false,
        builder: (context, snapshot) => IconButton.filled(
          tooltip: snapshot.data == true ? 'Pause' : 'Play',
          onPressed: files.isEmpty ? null : player.playOrPause,
          icon: Icon(snapshot.data == true ? Icons.pause : Icons.play_arrow),
        ),
      ),
      IconButton(
        tooltip: 'Forward 10 seconds',
        onPressed: files.isEmpty ? null : () => jump(10),
        icon: const Icon(Icons.forward_10),
      ),
      IconButton(
        tooltip: 'Next video',
        onPressed: files.isEmpty ? null : player.next,
        icon: const Icon(Icons.skip_next),
      ),
    ],
  );

  Widget _displayControls() => Row(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      DropdownButton<double>(
        value: speed,
        items: [0.5, 1.0, 1.5, 2.0, 4.0]
            .map((s) => DropdownMenuItem(value: s, child: Text('${s}x')))
            .toList(),
        onChanged: files.isEmpty
            ? null
            : (value) {
                if (value == null) return;
                setState(() => speed = value);
                player.setRate(value);
              },
      ),
      IconButton(
        tooltip: 'Rotate video 90 degrees',
        onPressed: () => setState(() => turns = (turns + 1) % 4),
        icon: const Icon(Icons.rotate_right),
      ),
      IconButton(
        tooltip: fill ? 'Fit video to screen' : 'Fill screen',
        onPressed: () => setState(() => fill = !fill),
        icon: const Icon(Icons.fit_screen),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Droid Vid Player'),
        actions: [
          IconButton(
            onPressed: openFiles,
            tooltip: 'Open local videos',
            icon: const Icon(Icons.folder_open),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: ColoredBox(
            color: Colors.black,
            child: files.isEmpty
                ? const Center(child: Text('Open a video to begin'))
                : ClipRect(
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
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(error!, style: const TextStyle(color: Colors.redAccent)),
          ),
      ]),
      bottomNavigationBar: SafeArea(
        top: false,
        // Extra clearance in addition to the Android system navigation inset.
        minimum: const EdgeInsets.fromLTRB(8, 6, 8, 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _seekBar(),
                if (wide)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _transportControls(),
                      _displayControls(),
                    ],
                  )
                else ...[
                  _transportControls(),
                  _displayControls(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
