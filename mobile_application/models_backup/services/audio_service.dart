import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_config.dart';

class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;
  AudioService._internal();

  final ApiConfig _config = ApiConfig();
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;

  final StreamController<Map<String, dynamic>> _liveTranscriptController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get liveTranscriptStream => _liveTranscriptController.stream;

  bool _isWsConnected = false;
  bool get isWsConnected => _isWsConnected;

  Future<Map<String, dynamic>> checkHealth() async {
    try {
      final resp = await http.get(_config.endpoint('/health')).timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        return {
          'online': true,
          'status': 'OK',
          'data': jsonDecode(resp.body),
        };
      }
    } catch (e) {
      return {'online': false, 'error': e.toString()};
    }
    return {'online': false};
  }

  Future<Map<String, dynamic>> startSession({
    required String title,
    String? seminarTopic,
    String source = 'server_mic',
  }) async {
    try {
      final resp = await http.post(
        _config.endpoint('/api/v1/session/start'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': title,
          'seminar_topic': seminarTopic ?? 'Computer Science, AI & Machine Learning Lecture',
          'source': source,
        }),
      ).timeout(const Duration(seconds: 6));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        connectLiveTranscript();
        return data;
      }
    } catch (_) {}

    // Fallback simulation if server is offline
    connectLiveTranscript();
    return {
      'session_id': 'session_${DateTime.now().millisecondsSinceEpoch}',
      'title': title,
      'status': 'ACTIVE',
      'mock': true,
    };
  }

  Future<Map<String, dynamic>> stopSession() async {
    try {
      final resp = await http.post(
        _config.endpoint('/api/v1/session/stop'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 6));

      if (resp.statusCode == 200) {
        disconnectLiveTranscript();
        return jsonDecode(resp.body);
      }
    } catch (_) {}

    disconnectLiveTranscript();
    return {
      'status': 'COMPLETED',
      'mock': true,
    };
  }

  void connectLiveTranscript() {
    disconnectLiveTranscript();
    try {
      final uri = _config.wsTranscriptUri;
      _wsChannel = WebSocketChannel.connect(uri);
      _isWsConnected = true;

      _wsSubscription = _wsChannel!.stream.listen(
        (message) {
          try {
            final parsed = jsonDecode(message.toString());
            if (parsed is Map<String, dynamic>) {
              _liveTranscriptController.add(parsed);
            }
          } catch (_) {}
        },
        onError: (_) {
          _isWsConnected = false;
        },
        onDone: () {
          _isWsConnected = false;
        },
      );
    } catch (_) {
      _isWsConnected = false;
    }
  }

  void disconnectLiveTranscript() {
    _wsSubscription?.cancel();
    _wsSubscription = null;
    _wsChannel?.sink.close();
    _wsChannel = null;
    _isWsConnected = false;
  }

  Future<bool> overrideChunk(String chunkId, String status) async {
    try {
      final resp = await http.patch(
        _config.endpoint('/api/v1/chunk/$chunkId/override'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'status': status}),
      ).timeout(const Duration(seconds: 4));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> editChunkText(String chunkId, String text) async {
    try {
      final resp = await http.patch(
        _config.endpoint('/api/v1/chunk/$chunkId/text'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': text}),
      ).timeout(const Duration(seconds: 4));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
