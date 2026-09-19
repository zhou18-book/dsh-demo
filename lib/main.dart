import 'package:flutter/material.dart';

import 'library/library_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EbookReaderApp());
}

class EbookReaderApp extends StatelessWidget {
  const EbookReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '阅读',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4D6BFE),
      ),
      home: const LibraryPage(),
    );
  }
}
