import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart' as drop;
import '../services/ocr_service.dart';

class _FileItem {
  final String name;
  final String path;
  _FileItem(this.name, this.path);
}

class OcrPage extends StatefulWidget {
  const OcrPage({super.key});

  @override
  State<OcrPage> createState() => _OcrPageState();
}

class _OcrPageState extends State<OcrPage> {
  List<_FileItem> _selectedFiles = [];
  List<OCRResult>? _results;
  bool _isProcessing = false;
  bool _isDragging = false;
  String? _error;

  Future<void> _pickImages() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result != null && result.files.isNotEmpty) {
      _addFiles(result.files.map((f) => _FileItem(f.name, f.path ?? '')).toList());
    }
  }

  void _addFiles(List<_FileItem> files) {
    setState(() {
      _selectedFiles = files;
      _results = null;
      _error = null;
    });
  }

  void _onDrop(drop.DropDoneDetails details) {
    setState(() => _isDragging = false);
    const imageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tiff', '.tif', '.heic', '.webp'};
    final imageFiles = details.files
        .where((f) => imageExtensions.any((ext) => f.name.toLowerCase().endsWith(ext)))
        .map((f) => _FileItem(f.name, f.path))
        .toList();
    if (imageFiles.isEmpty) return;
    _addFiles(imageFiles);
  }

  String _allText() =>
      _results?.map((r) => '--- ${r.filename} ---\n${r.text}').join('\n\n') ?? '';

  Future<void> _copyAll() async {
    final text = _allText();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied all text to clipboard'), duration: Duration(seconds: 2)),
      );
    }
  }

  Future<void> _saveToFile() async {
    final text = _allText();
    if (text.isEmpty) return;
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return;
    final path = '$dir/ocr_results_${DateTime.now().millisecondsSinceEpoch}.txt';
    try {
      await File(path).writeAsString(text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to $path'), duration: const Duration(seconds: 3)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _copySingle(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 2)),
      );
    }
  }

  Future<void> _processImages() async {
    if (_selectedFiles.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _error = null;
    });

    try {
      final paths = _selectedFiles.map((f) => f.path).toList();
      final results = await OcrService.recognizeText(paths);
      setState(() {
        _results = results;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasFiles = _selectedFiles.isNotEmpty;
    final hasResults = _results != null && _results!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('OCR Batch Processor'),
        centerTitle: true,
      ),
      body: drop.DropTarget(
        onDragEntered: (_) => setState(() => _isDragging = true),
        onDragExited: (_) => setState(() => _isDragging = false),
        onDragDone: _onDrop,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Pick images button
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _pickImages,
                    icon: const Icon(Icons.image_search),
                    label: const Text('Pick Image(s)'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),

                  const SizedBox(height: 8),
                  Text(
                    '… or drop images anywhere on this window',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),

                  if (hasFiles) ...[
                    const SizedBox(height: 12),

                    // Selected files info
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline),
                            const SizedBox(width: 8),
                            Text('${_selectedFiles.length} file(s) selected'),
                            const Spacer(),
                            Text(
                              _selectedFiles.length > 1 ? '${_selectedFiles.length} images' : '1 image',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Process button
                    ElevatedButton.icon(
                      onPressed: _isProcessing ? null : _processImages,
                      icon: _isProcessing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.text_snippet),
                      label: Text(_isProcessing ? 'Processing...' : 'Run OCR'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Card(
                      color: Colors.red.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(Icons.error, color: Colors.red.shade700),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_error!, style: TextStyle(color: Colors.red.shade700))),
                          ],
                        ),
                      ),
                    ),
                  ],

                  if (hasResults) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          'Results (${_results!.length} file(s)):',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          tooltip: 'Copy all',
                          onPressed: _copyAll,
                        ),
                        IconButton(
                          icon: const Icon(Icons.save_alt, size: 18),
                          tooltip: 'Save as .txt',
                          onPressed: _saveToFile,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _results!.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final r = _results![index];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.description, size: 18),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          r.filename,
                                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.copy, size: 16),
                                        tooltip: 'Copy text',
                                        onPressed: () => _copySingle(r.text),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: SelectableText(
                                      r.text.isNotEmpty ? r.text : '(no text recognized)',
                                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  // Empty state
                  if (!hasFiles && !hasResults && _error == null)
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.photo_library_outlined, size: 64, color: Colors.grey.shade400),
                            const SizedBox(height: 16),
                            Text(
                              'Select one or more images\nto extract text',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'or drag & drop them here',
                              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Drop overlay when dragging
            if (_isDragging)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_upload_outlined, size: 64, color: Colors.blue.shade400),
                        const SizedBox(height: 12),
                        Text(
                          'Drop images here',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
