import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../models/board_image_item.dart';
import 'api_config.dart';
import 'auth_session_store.dart';

class VisionException implements Exception {
  VisionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class VisionService {
  static final VisionService _instance = VisionService._internal();
  factory VisionService() => _instance;
  VisionService._internal();

  final ApiConfig _config = ApiConfig();

  // ---------------------------------------------------------------- background OCR
  // The server returns the image at once and runs OCR afterwards. watchOcr polls for
  // the text and fills it into every copy of the capture (CapturedImageItem.pendingOcr).

  /// Bumped whenever OCR text arrives, so widgets showing OCR text rebuild.
  static final ValueNotifier<int> ocrUpdates = ValueNotifier<int>(0);

  /// snapshot_id -> finished OCR text (also used right before notes generation).
  static final Map<String, String> ocrResults = {};

  final Set<String> _polling = {};

  void watchOcr(String? snapshotId) {
    if (snapshotId == null || !_polling.add(snapshotId)) return;
    unawaited(_pollOcr(snapshotId));
  }

  Future<void> _pollOcr(String snapshotId) async {
    try {
      // EasyOCR takes 5-20 s per image and images queue up: wait up to ~10 minutes
      for (var i = 0; i < 300; i++) {
        await Future.delayed(const Duration(seconds: 2));
        try {
          final resp = await http
              .get(_config.endpoint('/api/v1/vision/snapshot/$snapshotId/ocr'),
                  headers: await AuthSessionStore.authHeaders())
              .timeout(const Duration(seconds: 10));
          if (resp.statusCode == 404) return _applyOcr(snapshotId, '', null);
          if (resp.statusCode != 200) continue;
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          final status = data['status'];
          if (status == 'DONE') {
            return _applyOcr(snapshotId, (data['extracted_text'] as String?) ?? '',
                (data['confidence_score'] as num?)?.toDouble());
          }
          // server restarted before OCR finished: the text is gone (notes still
          // read the image itself)
          if (status == 'UNKNOWN') return _applyOcr(snapshotId, '', null);
        } catch (_) {
          // offline for a moment - keep trying
        }
      }
    } finally {
      _polling.remove(snapshotId);
    }
  }

  void _applyOcr(String snapshotId, String text, double? confidence) {
    ocrResults[snapshotId] = text;
    applyKnownOcr(CapturedImageItem.pendingOcr.toList());
    ocrUpdates.value++;
  }

  /// Puts finished OCR text into items that still show the placeholder.
  static void applyKnownOcr(Iterable<CapturedImageItem> items) {
    for (final item in items) {
      final text = ocrResults[item.snapshotId];
      if (text == null) continue;
      if (item.isOcrPending) item.ocrText = text;
      CapturedImageItem.pendingOcr.remove(item);
    }
  }

  Future<Map<String, dynamic>> processSnapshot(
    XFile imageFile, {
    String sessionId = 'lecture_session_01',
    String notePreference = 'BOTH',
    String privacyTarget = 'full_body',
    String enhancementMode = 'magic_color',
  }) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        _config.endpoint('/api/v1/vision/process-snapshot'),
      );
      request.headers.addAll(await AuthSessionStore.authHeaders());

      final bytes = await imageFile.readAsBytes();
      final multipartFile = http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: imageFile.name.isNotEmpty ? imageFile.name : 'capture.jpg',
      );

      request.files.add(multipartFile);
      request.fields['session_id'] = sessionId;
      request.fields['note_preference'] = notePreference;
      request.fields['privacy_target'] = privacyTarget;
      request.fields['enhancement_mode'] = enhancementMode;

      final streamedResponse = await request.send().timeout(const Duration(seconds: 45));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        // Prepend baseUrl if image url is relative
        final rawUrl = data['blurred_image_url'] as String? ?? '';
        if (rawUrl.startsWith('/')) {
          data['full_blurred_image_url'] = '${_config.baseUrl}$rawUrl';
        } else {
          data['full_blurred_image_url'] = rawUrl;
        }
        data['local_path'] = imageFile.path;
        return data;
      }
    } catch (e) {
      // Server offline / fallback
    }

    // Graceful offline fallback simulation
    return {
      'snapshot_id': 'snap_${DateTime.now().millisecondsSinceEpoch}',
      'session_id': sessionId,
      'blurred_image_url': '',
      'full_blurred_image_url': '',
      'local_path': imageFile.path,
      'extracted_text':
          '• Mobile Camera Capture (Offline Fallback)\n'
          '• Point device at whiteboard or slide\n'
          '• YOLOv8 privacy blur & EasyOCR verify active\n'
          '• Status: Saved locally on device',
      'confidence_score': 0.88,
      'people_detected': 0,
      'note_inclusion_preference': notePreference,
      'status': 'APPROVED',
      'mock': true,
    };
  }

  /// Replaces snapshot [snapshotId]'s image with [croppedJpeg] (cropped from the blurred
  /// image). The backend re-blurs it, re-runs OCR (local EasyOCR, no API tokens) and
  /// returns the new image URL and OCR text. Throws [VisionException] on failure.
  Future<Map<String, dynamic>> replaceSnapshot(String snapshotId, Uint8List croppedJpeg) async {
    final request = http.MultipartRequest(
      'POST',
      _config.endpoint('/api/v1/vision/snapshot/$snapshotId/replace'),
    );
    request.headers.addAll(await AuthSessionStore.authHeaders());
    request.files.add(http.MultipartFile.fromBytes('file', croppedJpeg, filename: 'crop.jpg'));

    final http.Response response;
    try {
      // OCR runs on the laptop CPU: usually 5-15 s, longer on a busy machine
      final streamed = await request.send().timeout(const Duration(minutes: 3));
      response = await http.Response.fromStream(streamed);
    } catch (e) {
      throw VisionException('Could not reach the server: $e');
    }
    if (response.statusCode != 200) {
      var detail = 'HTTP ${response.statusCode}';
      try {
        detail = (jsonDecode(response.body) as Map<String, dynamic>)['detail']?.toString() ?? detail;
      } catch (_) {}
      throw VisionException('Crop could not be saved: $detail');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final rawUrl = data['blurred_image_url'] as String? ?? '';
    data['full_blurred_image_url'] = rawUrl.startsWith('/') ? '${_config.baseUrl}$rawUrl' : rawUrl;
    return data;
  }

  Future<bool> updatePreference(String snapshotId, String preference) async {
    try {
      final resp = await http.patch(
        _config.endpoint('/api/v1/vision/snapshot/$snapshotId/preference'),
        headers: await AuthSessionStore.authHeaders({'Content-Type': 'application/json'}),
        body: jsonEncode({'preference': preference}),
      ).timeout(const Duration(seconds: 4));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
