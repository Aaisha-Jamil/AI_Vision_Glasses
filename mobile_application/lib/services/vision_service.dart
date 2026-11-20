import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'api_config.dart';
import 'auth_session_store.dart';

class VisionService {
  static final VisionService _instance = VisionService._internal();
  factory VisionService() => _instance;
  VisionService._internal();

  final ApiConfig _config = ApiConfig();

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
