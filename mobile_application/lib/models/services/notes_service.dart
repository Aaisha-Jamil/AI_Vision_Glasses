
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_config.dart';

class NotesServiceException implements Exception {
  NotesServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NotesService {
  static final NotesService _instance = NotesService._internal();

  factory NotesService() => _instance;

  NotesService._internal();

  final ApiConfig _config = ApiConfig();

  /// Generates notes using the real FastAPI backend.
  ///
  /// There is deliberately no local/demo fallback.
  Future<Map<String, dynamic>> generateNotes({
    required String sessionId,
    String? userId,
    Map<String, dynamic>? sessionData,
  }) async {
    if (sessionId.trim().isEmpty) {
      throw NotesServiceException('Session ID is missing.');
    }

    final uri = _config.endpoint('/api/v1/notes/generate');

    final payload = <String, dynamic>{
      'session_id': sessionId,
      'user_id': userId ?? 'default_user',
      if (sessionData != null) 'session_data': sessionData,
    };

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 120));

      Map<String, dynamic> data = {};

      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        }
      } catch (_) {
        // The server may return a non-JSON error response.
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = data['detail'] ??
            data['message'] ??
            'Backend returned HTTP ${response.statusCode}.';

        throw NotesServiceException(detail.toString());
      }

      if (data['status'] != 'success') {
        throw NotesServiceException(
          (data['message'] ?? 'Notes generation failed.').toString(),
        );
      }

      final content = data['markdown_content'];

      if (content == null || content.toString().trim().isEmpty) {
        throw NotesServiceException(
          'Backend returned empty notes content.',
        );
      }

      return data;
    } on NotesServiceException {
      rethrow;
    } on http.ClientException catch (e) {
      throw NotesServiceException(
        'Could not connect to the backend: ${e.message}',
      );
    } catch (e) {
      if (e.toString().contains('TimeoutException')) {
        throw NotesServiceException(
          'Notes generation timed out. Please try again.',
        );
      }

      throw NotesServiceException(
        'Notes generation request failed: $e',
      );
    }
  }

  /// Fetches an existing generated note for a session.
  Future<Map<String, dynamic>?> fetchSessionNote(
    String sessionId,
  ) async {
    try {
      final uri = _config.endpoint(
        '/api/v1/notes/session/${Uri.encodeComponent(sessionId)}',
      );

      final response = await http
          .get(
            uri,
            headers: {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      }
    } catch (_) {
      // Caller can handle an unavailable existing note.
    }

    return null;
  }

  /// Backend DOCX download endpoint.
  Uri getDocxDownloadUri(String sessionId) {
    return _config.endpoint(
      '/api/v1/notes/${Uri.encodeComponent(sessionId)}/docx',
    );
  }
}
