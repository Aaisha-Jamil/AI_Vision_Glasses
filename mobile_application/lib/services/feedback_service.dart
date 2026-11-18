// Sends and retrieves feedback through FastAPI using the signed-in user's access token.
// The backend determines feedback ownership; the app never supplies a trusted user_id.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/feedback_item.dart';
import 'api_config.dart';
import 'auth_session_store.dart';

class FeedbackService {
  FeedbackService._();

  static final FeedbackService instance = FeedbackService._();

  Future<FeedbackItem> submit({
    required int rating,
    required String category,
    String? comments,
    String? sessionId,
    String? noteId,
  }) async {
    final token = await _requiredToken();
    final response = await http.post(
      ApiConfig().endpoint('/api/v1/feedback'),
      headers: _headers(token),
      body: jsonEncode({
        'rating': rating,
        'category': category,
        if (comments != null && comments.trim().isNotEmpty) 'comments': comments.trim(),
        if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
        if (noteId != null && noteId.isNotEmpty) 'note_id': noteId,
      }),
    );
    return FeedbackItem.fromJson(_decode(response));
  }

  Future<List<FeedbackItem>> getMyFeedback({int limit = 50}) async {
    final token = await _requiredToken();
    final response = await http.get(
      ApiConfig().endpoint('/api/v1/feedback?limit=$limit'),
      headers: _headers(token),
    );
    final data = _decode(response);
    final items = data['items'];
    if (items is! List) return [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(FeedbackItem.fromJson)
        .toList();
  }

  Future<String> _requiredToken() async {
    final token = await AuthSessionStore.readAccessToken();
    if (token == null || token.isEmpty) {
      throw FeedbackException('Please log in before submitting feedback.');
    }
    return token;
  }

  Map<String, String> _headers(String token) => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      };

  Map<String, dynamic> _decode(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Feedback request failed (${response.statusCode}).';
      if (decoded is Map && decoded['detail'] != null) {
        final detail = decoded['detail'];
        message = detail is Map
            ? (detail['message'] ?? detail['code'] ?? message).toString()
            : detail.toString();
      }
      throw FeedbackException(message);
    }

    if (decoded is! Map<String, dynamic>) {
      throw FeedbackException('Server returned an invalid response.');
    }
    return decoded;
  }
}

class FeedbackException implements Exception {
  FeedbackException(this.message);
  final String message;

  @override
  String toString() => message;
}
