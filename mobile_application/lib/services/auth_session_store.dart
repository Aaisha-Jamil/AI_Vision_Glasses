// Stores the access token in the platform secure storage.
// Supabase access tokens can be stored here after the team connects the real Auth provider.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthSessionStore {
  AuthSessionStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _accessTokenKey = 'ai_vision_access_token';

  static Future<void> saveAccessToken(String token) {
    return _storage.write(key: _accessTokenKey, value: token);
  }

  static Future<String?> readAccessToken() {
    return _storage.read(key: _accessTokenKey);
  }

  static Future<void> clear() {
    return _storage.delete(key: _accessTokenKey);
  }
}
