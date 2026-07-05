import 'dart:async';
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

  // Benchmark tracking
  Stopwatch _stopwatch = Stopwatch();
  Timer? _elapsedTimer;
  double _elapsedSeconds = 0;
  double _totalProcessedSeconds = 0; // sum of per-file durations from Swift

  Future<void> _pickImages() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result != null && result.files.isNotEmpty) {
      _addFiles(result.files.map((f) => _FileItem(f.name, f.path ?? '')).toList());
    }
  }

  static const _imageExtensions = {
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tiff', '.tif', '.heic', '.webp',
  };

  /// Recursively scan [directory] for files with supported image extensions.
  /// Skips hidden entries (names starting with '.').
  List<_FileItem> _collectImagesFromDirectory(Directory directory) {
    final items = <_FileItem>[];
    try {
      final entities = directory.listSync(followLinks: false);
      for (final entity in entities) {
        if (entity is Directory) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (!name.startsWith('.')) {
            items.addAll(_collectImagesFromDirectory(entity));
          }
        } else if (entity is File) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (_imageExtensions.any((ext) => name.toLowerCase().endsWith(ext))) {
            items.add(_FileItem(name, entity.path));
          }
        }
      }
    } catch (_) {
      // Skip directories that can't be read.
    }
    return items;
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
    final allFiles = <_FileItem>[];
    for (final f in details.files) {
      final entity = FileSystemEntity.typeSync(f.path);
      if (entity == FileSystemEntityType.directory) {
        allFiles.addAll(_collectImagesFromDirectory(Directory(f.path)));
      } else if (_imageExtensions.any((ext) => f.name.toLowerCase().endsWith(ext))) {
        allFiles.add(_FileItem(f.name, f.path));
      }
    }
    if (allFiles.isEmpty) return;
    _addFiles(allFiles);
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
      _elapsedSeconds = 0;
      _totalProcessedSeconds = 0;
    });

    // Start elapsed-time timer
    _stopwatch.reset();
    _stopwatch.start();
    _elapsedTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() {
        _elapsedSeconds = _stopwatch.elapsedMilliseconds / 1000.0;
      });
    });

    try {
      final paths = _selectedFiles.map((f) => f.path).toList();
      final results = await OcrService.recognizeText(paths);
      _stopwatch.stop();
      _elapsedTimer?.cancel();
      _elapsedSeconds = _stopwatch.elapsedMilliseconds / 1000.0;
      _totalProcessedSeconds = results.fold<double>(0, (s, r) => s + r.duration);
      setState(() {
        _results = results;
        _isProcessing = false;
      });
    } catch (e) {
      _stopwatch.stop();
      _elapsedTimer?.cancel();
      setState(() {
        _error = e.toString();
        _isProcessing = false;
      });
    }
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    super.dispose();
  }

  // ─── Benchmark helpers ───

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
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
                    '… or drop images/folders anywhere on this window',
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
                      label: Text(_isProcessing ? 'Processing…' : 'Run OCR'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    ),

                    // Elapsed time while processing
                    if (_isProcessing)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '⏱ ${_elapsedSeconds.toStringAsFixed(1)}s elapsed  •  ${_selectedFiles.length} images',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
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

                  // Benchmark summary card
                  if (hasResults) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: Colors.blue.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.speed, size: 18, color: Colors.blue.shade700),
                                const SizedBox(width: 6),
                                Text('Benchmark',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue.shade700)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            _statRow('Wall-clock time', '${_elapsedSeconds.toStringAsFixed(3)}s'),
                            _statRow('Sum of durations', '${_totalProcessedSeconds.toStringAsFixed(3)}s'),
                            _statRow('Average per image',
                              '${(_totalProcessedSeconds / _results!.length).toStringAsFixed(3)}s'),
                            _statRow('Throughput',
                              '${(_results!.length / _elapsedSeconds).toStringAsFixed(1)} images/s'),
                            _statRow('Successful', '${_results!.where((r) => r.text.isNotEmpty).length}'),
                            _statRow('Empty', '${_results!.where((r) => r.text.isEmpty && r.error == null).length}'),
                            if (_results!.any((r) => r.error != null))
                              _statRow('Failed', '${_results!.where((r) => r.error != null).length}'),
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
                              'Select images or folders\nto extract text',
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
                          'Drop images or folders here',
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
