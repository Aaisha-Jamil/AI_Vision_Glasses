import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiConfig {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _baseUrlKey = 'ai_vision_backend_url';

  /// Restores the server URL saved on this device (call once before runApp).
  Future<void> load() async {
    try {
      final saved = await _storage.read(key: _baseUrlKey);
      if (saved != null && saved.isNotEmpty) _baseUrl = saved;
    } catch (e) {
      debugPrint('ApiConfig: could not read saved server URL: $e');
    }
  }

  static final ApiConfig _instance = ApiConfig._internal();
  factory ApiConfig() => _instance;

  ApiConfig._internal() {
    // Android emulator maps 10.0.2.2 to the host PC's localhost.
    // For a physical phone on Wi-Fi, the user can change this to http://192.168.x.x:8000.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _baseUrl = 'http://10.0.2.2:8000';
    } else {
      _baseUrl = 'http://localhost:8000';
    }
  }

  String _baseUrl = 'http://localhost:8000';

  String get baseUrl => _baseUrl;

  void setBaseUrl(String url) {
    var cleaned = url.trim();
    if (cleaned.isEmpty) return;
    if (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (!cleaned.startsWith('http://') && !cleaned.startsWith('https://')) {
      cleaned = 'http://$cleaned';
    }
    _baseUrl = cleaned;
    _storage.write(key: _baseUrlKey, value: cleaned).catchError(
          (Object e) => debugPrint('ApiConfig: could not save server URL: $e'),
        );
  }

  Uri endpoint(String path) {
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$_baseUrl$cleanPath');
  }

  Uri resolveUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }
    return endpoint(path);
  }

  Uri get wsTranscriptUri {
    final wsBase = _baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    return Uri.parse('$wsBase/ws/transcript');
  }
}
