import 'package:flutter/foundation.dart';

class ApiConfig {
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
  }

  Uri endpoint(String path) {
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$_baseUrl$cleanPath');
  }

  Uri get wsTranscriptUri {
    final wsBase = _baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    return Uri.parse('$wsBase/ws/transcript');
  }
}
