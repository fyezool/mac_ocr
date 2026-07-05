// Flutter benchmark entry point.
//
// Usage:
//   flutter run -d macos --target lib/benchmark_main.dart \
//     --dart-entrypoint-args=--benchmark,<folder-path>
//
// Or use the convenience script:  tool/flutter_benchmark.sh <folder-path>

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'services/ocr_service.dart';

void main(List<String> args) async {
  // Parse arguments before starting the engine.
  String? folderPath;
  for (final arg in args) {
    if (arg.startsWith('--benchmark')) {
      final parts = arg.split(',');
      if (parts.length >= 2) {
        folderPath = parts.sublist(1).join(',');
      }
    }
  }

  if (folderPath == null || folderPath.isEmpty) {
    stderr.writeln('Usage: --benchmark,<folder-path>');
    exit(1);
  }

  final folder = Directory(folderPath);
  if (!folder.existsSync()) {
    stderr.writeln('Error: directory not found: $folderPath');
    exit(1);
  }

  // Start the Flutter engine (required for MethodChannel to work on macOS).
  runApp(_BenchmarkApp(folderPath: folderPath));
}

/// Minimal app that runs the benchmark and exits.
class _BenchmarkApp extends StatefulWidget {
  final String folderPath;
  const _BenchmarkApp({required this.folderPath});

  @override
  State<_BenchmarkApp> createState() => _BenchmarkAppState();
}

class _BenchmarkAppState extends State<_BenchmarkApp> {
  @override
  void initState() {
    super.initState();
    // Kick off after the first frame so the engine is fully ready.
    WidgetsBinding.instance.addPostFrameCallback((_) => _runBenchmark());
  }

  Future<void> _runBenchmark() async {
    stderr.writeln('📁 Scanning "${widget.folderPath}" for images…');
    final images = await _collectImages(Directory(widget.folderPath));
    stderr.writeln('   found ${images.length} image(s).');

    if (images.isEmpty) {
      stderr.writeln('No images found.');
      exit(0);
    }

    stderr.writeln('🔍 Running OCR on ${images.length} image(s) via Flutter…');
    stderr.writeln('');

    final totalStart = DateTime.now();
    final results = await OcrService.recognizeText(images.map((f) => f.path).toList());
    final totalElapsed = DateTime.now().difference(totalStart).inMilliseconds / 1000.0;

    final totalDuration = results.fold<double>(0, (sum, r) => sum + r.duration);
    final avgDuration = results.isNotEmpty ? totalDuration / results.length : 0.0;
    final imagesPerSecond = totalElapsed > 0 ? results.length / totalElapsed : 0.0;
    final successful = results.where((r) => r.error == null && r.text.isNotEmpty).length;
    final failed = results.where((r) => r.error != null).length;
    final empty = results.where((r) => r.error == null && r.text.isEmpty).length;

    // Write JSON to stdout.
    final output = {
      'summary': {
        'total_images': results.length,
        'successful': successful,
        'empty': empty,
        'failed': failed,
        'wall_clock_seconds': totalElapsed,
        'sum_duration_seconds': totalDuration,
        'avg_duration_seconds': avgDuration,
        'images_per_second': imagesPerSecond,
      },
      'results': results.map((r) => {
        'filename': r.filename,
        'text': r.text,
        'error': r.error,
        'duration_seconds': r.duration,
      }).toList(),
    };

    final encoder = JsonEncoder.withIndent('  ');
    print(encoder.convert(output));

    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    // Invisible window — just a frame to keep the engine alive.
    return const MaterialApp(
      home: SizedBox.shrink(),
    );
  }

  /// Recursively collect supported image files from [directory].
  Future<List<FileSystemEntity>> _collectImages(Directory directory) async {
    const imageExtensions = {
      '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tiff', '.tif', '.heic', '.webp',
    };
    final items = <FileSystemEntity>[];

    try {
      await for (final entity in directory.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (!name.startsWith('.') && imageExtensions.any((ext) => name.toLowerCase().endsWith(ext))) {
            items.add(entity);
          }
        }
      }
    } catch (_) {
      // Skip unreadable paths.
    }

    return items;
  }
}
