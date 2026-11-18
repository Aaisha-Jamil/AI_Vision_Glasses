// Calls the FastAPI authentication endpoints and securely stores the returned access token.
// No local/demo login is implemented; authentication succeeds only when the real provider is connected.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/app_user.dart';
import 'api_config.dart';
import 'auth_session_store.dart';

class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  Future<AppUser> register({
    required String fullName,
    required String email,
    required String password,
  }) async {
    final data = await _post('/api/v1/auth/register', {
      'full_name': fullName.trim(),
      'email': email.trim().toLowerCase(),
      'password': password,
    });
    return _completeAuthentication(data);
  }

  Future<AppUser> login({
    required String email,
    required String password,
  }) async {
    final data = await _post('/api/v1/auth/login', {
      'email': email.trim().toLowerCase(),
      'password': password,
    });
    return _completeAuthentication(data);
  }

  Future<AppUser> currentUser() async {
    final token = await AuthSessionStore.readAccessToken();
    if (token == null || token.isEmpty) {
      throw AuthException('Please log in to continue.');
    }

    final response = await http.get(
      ApiConfig().endpoint('/api/v1/auth/me'),
      headers: _headers(token),
    );
    final data = _decodeResponse(response);
    return AppUser.fromJson(data);
  }

  Future<void> logout() async {
    final token = await AuthSessionStore.readAccessToken();
    try {
      if (token != null && token.isNotEmpty) {
        await http.post(
          ApiConfig().endpoint('/api/v1/auth/logout'),
          headers: _headers(token),
        );
      }
    } finally {
      await AuthSessionStore.clear();
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await http.post(
      ApiConfig().endpoint(path),
      headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
      body: jsonEncode(body),
    );
    return _decodeResponse(response);
  }

  Future<AppUser> _completeAuthentication(Map<String, dynamic> data) async {
    final token = data['access_token']?.toString();
    final userJson = data['user'];

    if (token == null || token.isEmpty || userJson is! Map<String, dynamic>) {
      throw AuthException('Authentication server returned an invalid response.');
    }

    await AuthSessionStore.saveAccessToken(token);
    return AppUser.fromJson(userJson);
  }

  Map<String, String> _headers(String token) => {
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      };

  Map<String, dynamic> _decodeResponse(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = 'Request failed (${response.statusCode}).';
      if (decoded is Map) {
        final detail = decoded['detail'];
        if (detail is Map) {
          message = (detail['message'] ?? detail['code'] ?? message).toString();
        } else if (detail != null) {
          message = detail.toString();
        }
      }
      throw AuthException(message);
    }

    if (decoded is! Map<String, dynamic>) {
      throw AuthException('Server returned an invalid response.');
    }
    return decoded;
  }
}

class AuthException implements Exception {
  AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}
