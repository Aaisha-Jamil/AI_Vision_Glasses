import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_config.dart';

class NotesService {
  static final NotesService _instance = NotesService._internal();
  factory NotesService() => _instance;
  NotesService._internal();

  final ApiConfig _config = ApiConfig();

  /// Requests the backend Python synthesis engine to generate academic lecture notes
  /// from the audio chunks and board snapshots of [sessionId].
  Future<Map<String, dynamic>> generateNotes({
    required String sessionId,
    String? userId,
    Map<String, dynamic>? sessionData,
  }) async {
    try {
      final uri = _config.endpoint('/api/v1/notes/generate');
      final payload = {
        'session_id': sessionId,
        'user_id': userId ?? 'default_user',
        'session_data': ?sessionData,
      };

      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data;
      }
    } catch (e) {
      // Backend offline, timeout or network error - will fall back to local synthesis
    }
    return {
      'status': 'offline',
      'message': 'Backend server offline or unreachable',
    };
  }

  /// Fetches an existing generated note for [sessionId] from the server.
  Future<Map<String, dynamic>?> fetchSessionNote(String sessionId) async {
    try {
      final uri = _config.endpoint('/api/v1/notes/session/$sessionId');
      final response = await http.get(uri).timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Returns the direct download URL for the generated .docx file on the backend server.
  Uri getDocxDownloadUri(String sessionId) {
    return _config.endpoint('/api/v1/notes/$sessionId/docx');
  }
}
