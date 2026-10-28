import 'package:flutter/material.dart';
import 'editor_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DroidVidEditorApp());
}

class DroidVidEditorApp extends StatelessWidget {
  const DroidVidEditorApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Droid Vid Editor',
    theme: ThemeData.dark(useMaterial3: true),
    home: const EditorScreen(),
  );
}
