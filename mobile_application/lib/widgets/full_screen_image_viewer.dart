// Full-screen board image viewer (pinch / scroll zoom) with "Crop & re-run OCR".
//
// Cropping always starts from the privacy-blurred image on the server (never the
// unblurred local photo). The crop is sent to the backend, which re-blurs it, re-runs
// OCR (local EasyOCR - no API tokens) and keeps the same snapshot id, so the notes
// later use the cropped image and its new OCR text.
import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/board_image_item.dart';
import '../services/vision_service.dart';
import 'image_loader.dart';

/// Opens [item] full screen. Returns true if the image was cropped and replaced.
Future<bool> openFullScreenImage(BuildContext context, CapturedImageItem item) async {
  final changed = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => FullScreenImageViewer(item: item)),
  );
  return changed ?? false;
}

class FullScreenImageViewer extends StatefulWidget {
  const FullScreenImageViewer({super.key, required this.item});

  final CapturedImageItem item;

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> {
  final _cropController = CropController();
  Uint8List? _cropSource; // non-null while in crop mode
  bool _busy = false;
  String? _busyText;
  bool _changed = false;

  CapturedImageItem get item => widget.item;
  bool get _hasRemote => (item.remoteImageUrl ?? '').isNotEmpty;
  bool get _canCrop => _hasRemote && (item.snapshotId ?? '').isNotEmpty;

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _startCrop() async {
    setState(() {
      _busy = true;
      _busyText = 'Loading image…';
    });
    try {
      final resp = await http.get(Uri.parse(item.remoteImageUrl!)).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      setState(() => _cropSource = resp.bodyBytes);
    } catch (e) {
      _toast('Could not load the image for cropping: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onCropped(CropResult result) async {
    switch (result) {
      case CropSuccess(:final croppedImage):
        setState(() => _busyText = 'Saving crop & running OCR again…');
        try {
          final data = await VisionService().replaceSnapshot(item.snapshotId!, croppedImage);
          final url = data['full_blurred_image_url'] as String? ?? '';
          item.remoteImageUrl = url.isNotEmpty ? url : item.remoteImageUrl;
          item.ocrText = (data['extracted_text'] as String?) ?? item.ocrText;
          item.confidenceScore = (data['confidence_score'] as num?)?.toDouble() ?? item.confidenceScore;
          item.peopleDetected = (data['people_detected'] as num?)?.toInt() ?? item.peopleDetected;
          _changed = true;
          if (!mounted) return;
          setState(() {
            _cropSource = null;
            _busy = false;
          });
          await _showOcrResult();
        } catch (e) {
          if (!mounted) return;
          setState(() => _busy = false);
          _toast(e.toString());
        }
      case CropFailure(:final cause):
        setState(() => _busy = false);
        _toast('Crop failed: $cause');
    }
  }

  Future<void> _showOcrResult() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Crop saved – new OCR text',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              Text('Confidence: ${((item.confidenceScore ?? 0) * 100).round()}%',
                  style: const TextStyle(fontSize: 12)),
              const Divider(),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
                child: SingleChildScrollView(
                  // rebuilds when background OCR text arrives
                  child: ValueListenableBuilder<int>(
                    valueListenable: VisionService.ocrUpdates,
                    builder: (context, _, _) => SelectableText(item.ocrText,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewer() {
    final Widget image;
    if (_hasRemote) {
      image = Image.network(
        item.remoteImageUrl!,
        fit: BoxFit.contain,
        loadingBuilder: (c, child, progress) =>
            progress == null ? child : const Center(child: CircularProgressIndicator()),
        errorBuilder: (c, e, s) => const Center(
          child: Text('Image could not be loaded', style: TextStyle(color: Colors.white70)),
        ),
      );
    } else {
      image = loadLocalImage(item.localImagePath) ??
          const Center(
            child: Text('No image available', style: TextStyle(color: Colors.white70)),
          );
    }
    return InteractiveViewer(minScale: 1, maxScale: 6, child: Center(child: image));
  }

  Widget _buildCropper() {
    return Column(
      children: [
        Expanded(
          child: Crop(
            image: _cropSource!,
            controller: _cropController,
            onCropped: _onCropped,
            baseColor: Colors.black,
            maskColor: Colors.black.withValues(alpha: 0.6),
            progressIndicator: const Center(child: CircularProgressIndicator()),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                    onPressed: _busy ? null : () => setState(() => _cropSource = null),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Save & re-run OCR'),
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() {
                              _busy = true;
                              _busyText = 'Cropping…';
                            });
                            _cropController.crop();
                          },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cropping = _cropSource != null;
    return PopScope(
      // system back: leave crop mode first, then close and report whether it changed
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _busy) return;
        if (_cropSource != null) {
          setState(() => _cropSource = null);
        } else {
          Navigator.of(context).pop(_changed);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(cropping ? 'Crop image' : item.title, overflow: TextOverflow.ellipsis),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _busy ? null : () => Navigator.of(context).pop(_changed),
          ),
          actions: [
            if (!cropping && _canCrop)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: _busy ? null : _startCrop,
                icon: const Icon(Icons.crop),
                label: const Text('Crop'),
              ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(child: cropping ? _buildCropper() : _buildViewer()),
            if (_busy)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 14),
                        Text(_busyText ?? '', style: const TextStyle(color: Colors.white)),
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
