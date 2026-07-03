import 'package:flutter/material.dart';
import 'pages/ocr_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OcrApp());
}

class OcrApp extends StatelessWidget {
  const OcrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OCR Batch Processor',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: const OcrPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
