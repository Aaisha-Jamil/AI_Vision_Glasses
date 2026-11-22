
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_config.dart';
import 'auth_session_store.dart';

/// [uri] with the signed-in user's token as ?token=... (WebSockets can't carry the
/// Authorization header from every platform, so the backend reads it from the URL).
Future<Uri> _withToken(Uri uri) async {
  final token = await AuthSessionStore.readAccessToken();
  if (token == null || token.isEmpty) return uri;
  return uri.replace(queryParameters: {...uri.queryParameters, 'token': token});
}

class AudioService {
  static final AudioService _instance = AudioService._internal();

  factory AudioService() => _instance;

  AudioService._internal();

  final ApiConfig _config = ApiConfig();

  final AudioRecorder _recorder = AudioRecorder();

  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;

  WebSocketChannel? _audioChannel;
  StreamSubscription<Uint8List>? _audioSubscription;

  final StreamController<Map<String, dynamic>>
      _liveTranscriptController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get liveTranscriptStream =>
      _liveTranscriptController.stream;

  bool _isWsConnected = false;
  bool get isWsConnected => _isWsConnected;

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  bool _isPaused = false;
  bool get isPaused => _isPaused;

  String? _lastAudioError;
  String? get lastAudioError => _lastAudioError;

  // ---------------------------------------------------------
  // BACKEND HEALTH
  // ---------------------------------------------------------

  Future<Map<String, dynamic>> checkHealth() async {
    try {
      final resp = await http
          .get(_config.endpoint('/health'))
          .timeout(const Duration(seconds: 5));

      if (resp.statusCode == 200) {
        return {
          'online': true,
          'status': 'OK',
          'data': jsonDecode(resp.body),
        };
      }

      return {
        'online': false,
        'statusCode': resp.statusCode,
      };
    } catch (e) {
      return {
        'online': false,
        'error': e.toString(),
      };
    }
  }

  // ---------------------------------------------------------
  // SMART GLASSES (ESP32-CAM) STATUS
  // ---------------------------------------------------------

  Future<Map<String, dynamic>> checkGlassesStatus() async {
    try {
      final resp = await http
          .get(_config.endpoint('/api/v1/glasses/status'))
          .timeout(const Duration(seconds: 3));

      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
      return {'connected': false};
    } catch (_) {
      return {'connected': false};
    }
  }

  // ---------------------------------------------------------
  // START SESSION
  // ---------------------------------------------------------

  Future<Map<String, dynamic>> startSession({
    required String title,
    String? seminarTopic,
    String source = 'browser',
  }) async {
    bool backendStarted = false;

    try {
      _lastAudioError = null;
      _isPaused = false;

      if (source == 'browser') {
        final hasPermission = await _recorder.hasPermission();

        if (!hasPermission) {
          throw Exception(
            'Microphone permission denied. Please allow microphone access.',
          );
        }
      }

      final resp = await http
          .post(
            _config.endpoint('/api/v1/session/start'),
            headers: await AuthSessionStore.authHeaders({
              'Content-Type': 'application/json',
            }),
            body: jsonEncode({
              'title': title,
              // no topic -> the backend's generic default (the user names the
              // lecture at stop time, see stopSession)
              if (seminarTopic != null && seminarTopic.trim().isNotEmpty)
                'seminar_topic': seminarTopic.trim(),
              'source': source,
            }),
          )
          // the first session after the server starts waits for the embedding model
          .timeout(const Duration(seconds: 90));

      if (resp.statusCode != 200) {
        throw Exception(
          'Backend session start failed: ${resp.statusCode} ${resp.body}',
        );
      }

      final data = jsonDecode(resp.body);

      if (data is! Map<String, dynamic>) {
        throw Exception('Invalid session response from backend.');
      }

      backendStarted = true;

      if (source == 'browser') {
        await _startMicrophoneStream();
      }

      await connectLiveTranscript();

      return data;
    } catch (e) {
      await _cleanupAudio();

      if (backendStarted) {
        try {
          await http
              .post(_config.endpoint('/api/v1/session/stop'),
                  headers: await AuthSessionStore.authHeaders())
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
      }

      throw Exception('Could not start recording: $e');
    }
  }

  // ---------------------------------------------------------
  // MICROPHONE -> /ws/audio
  // 16 kHz, mono, signed 16-bit PCM
  // ---------------------------------------------------------

  Future<void> _startMicrophoneStream() async {
    final httpUri = _config.endpoint('/ws/audio');

    final wsUri = await _withToken(httpUri.replace(
      scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
    ));

    _audioChannel = WebSocketChannel.connect(wsUri);

    await _audioChannel!.ready.timeout(
      const Duration(seconds: 10),
    );

    final audioStream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );

    _isRecording = true;
    _isPaused = false;

    _audioSubscription = audioStream.listen(
      (Uint8List audioBytes) {
        if (_audioChannel != null &&
            _isRecording &&
            !_isPaused) {
          try {
            _audioChannel!.sink.add(audioBytes);
          } catch (e) {
            _lastAudioError = e.toString();
          }
        }
      },
      onError: (Object error) {
        _lastAudioError = error.toString();
      },
      onDone: () {
        _isRecording = false;
        _isPaused = false;
      },
      cancelOnError: false,
    );
  }

  // ---------------------------------------------------------
  // PAUSE MICROPHONE
  // ---------------------------------------------------------

  Future<void> pauseRecording() async {
    if (!_isRecording || _isPaused) return;

    try {
      await _recorder.pause();
      _isPaused = true;
    } catch (e) {
      _lastAudioError = e.toString();
      rethrow;
    }
  }

  // ---------------------------------------------------------
  // RESUME MICROPHONE
  // ---------------------------------------------------------

  Future<void> resumeRecording() async {
    if (!_isRecording || !_isPaused) return;

    try {
      await _recorder.resume();
      _isPaused = false;
    } catch (e) {
      _lastAudioError = e.toString();
      rethrow;
    }
  }

  // ---------------------------------------------------------
  // STOP SESSION
  // ---------------------------------------------------------

  /// Stops the mic only (the backend session stays open), so no more audio is
  /// recorded while the user types the lecture name before [stopSession].
  Future<void> stopMicrophone() => _cleanupAudio();

  /// [title] becomes the session title; [seminarTopic] (the lecture name the user
  /// typed) is used by noise scoring, which runs on stop. Null = keep the start values.
  Future<Map<String, dynamic>> stopSession({
    String? title,
    String? seminarTopic,
  }) async {
    try {
      await _cleanupAudio();

      final resp = await http
          .post(
            _config.endpoint('/api/v1/session/stop'),
            headers: await AuthSessionStore.authHeaders({
              'Content-Type': 'application/json',
            }),
            body: jsonEncode({
              if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
              if (seminarTopic != null && seminarTopic.trim().isNotEmpty)
                'seminar_topic': seminarTopic.trim(),
            }),
          )
          // scoring runs on stop (embeddings + maybe one LLM session check)
          .timeout(const Duration(seconds: 45));

      if (resp.statusCode != 200) {
        throw Exception(
          'Backend session stop failed: ${resp.statusCode} ${resp.body}',
        );
      }

      disconnectLiveTranscript();

      final data = jsonDecode(resp.body);

      if (data is Map<String, dynamic>) {
        return data;
      }

      throw Exception('Invalid stop-session response.');
    } catch (e) {
      disconnectLiveTranscript();
      throw Exception('Could not stop recording: $e');
    }
  }

  // ---------------------------------------------------------
  // CLEANUP AUDIO
  // ---------------------------------------------------------

  Future<void> _cleanupAudio() async {
    _isRecording = false;
    _isPaused = false;

    await _audioSubscription?.cancel();
    _audioSubscription = null;

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}

    try {
      await _audioChannel?.sink.close();
    } catch (_) {}

    _audioChannel = null;
  }

  // ---------------------------------------------------------
  // LIVE TRANSCRIPT WEBSOCKET
  // ---------------------------------------------------------

  Future<void> connectLiveTranscript() async {
    disconnectLiveTranscript();

    try {
      // without the token the server closes the socket (it only sends a user's own events)
      final uri = await _withToken(_config.wsTranscriptUri);

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
        onError: (Object error) {
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

    try {
      _wsChannel?.sink.close();
    } catch (_) {}

    _wsChannel = null;
    _isWsConnected = false;
  }

  // ---------------------------------------------------------
  // REVIEW / OVERRIDE CHUNK
  // ---------------------------------------------------------

  Future<bool> overrideChunk(
    String chunkId,
    String status,
  ) async {
    try {
      final resp = await http
          .patch(
            _config.endpoint('/api/v1/chunk/$chunkId/override'),
            headers: await AuthSessionStore.authHeaders({
              'Content-Type': 'application/json',
            }),
            body: jsonEncode({
              'status': status,
            }),
          )
          .timeout(const Duration(seconds: 5));

      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------
  // EDIT TRANSCRIPT CHUNK
  // ---------------------------------------------------------

  Future<bool> editChunkText(
    String chunkId,
    String text,
  ) async {
    try {
      final resp = await http
          .patch(
            _config.endpoint('/api/v1/chunk/$chunkId/text'),
            headers: await AuthSessionStore.authHeaders({
              'Content-Type': 'application/json',
            }),
            body: jsonEncode({
              'text': text,
            }),
          )
          .timeout(const Duration(seconds: 5));

      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------
  // DISPOSE
  // ---------------------------------------------------------

  Future<void> dispose() async {
    await _cleanupAudio();
    disconnectLiveTranscript();

    await _recorder.dispose();
    await _liveTranscriptController.close();
  }
}
