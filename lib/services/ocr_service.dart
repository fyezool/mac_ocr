import 'package:flutter/services.dart';

class OCRResult {
  final String filename;
  final String text;
  final String? error;
  final double duration;  // seconds spent on this file

  OCRResult({
    required this.filename,
    required this.text,
    this.error,
    this.duration = 0,
  });

  factory OCRResult.fromJson(Map json) {
    return OCRResult(
      filename: json['filename'] as String? ?? '',
      text: json['text'] as String? ?? '',
      error: json['error'] as String?,
      duration: (json['duration'] as num?)?.toDouble() ?? 0,
    );
  }
}

class OcrService {
  static const _channel = MethodChannel('com.ocr.app/ocr');

  static Future<List<OCRResult>> recognizeText(List<String> imagePaths) async {
    try {
      final result = await _channel.invokeMethod('recognizeText', {
        'paths': imagePaths,
      });
      if (result is List) {
        return result.map((e) => OCRResult.fromJson(e as Map)).toList();
      }
      return [];
    } on PlatformException catch (e) {
      throw Exception('OCR failed: ${e.message}');
    }
  }
}
