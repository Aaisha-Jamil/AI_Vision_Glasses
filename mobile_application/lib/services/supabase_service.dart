import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/board_image_item.dart';
import '../models/note.dart';
import '../models/saved_input.dart';
import '../models/transcript_line_item.dart';

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  String supabaseUrl = 'https://njojrbptyjgwlmwjhchx.supabase.co';
  String supabaseKey = 'sb_publishable_jz5MuoMdwBty3fP9eto5Gw_81QWD0wY';

  Map<String, String> get _headers => {
        'apikey': supabaseKey,
        'Authorization': 'Bearer $supabaseKey',
        'Content-Type': 'application/json',
        'Prefer': 'return=representation',
      };

  // ===========================================================================
  // SESSIONS (FETCH, INSERT, UPDATE, DELETE)
  // ===========================================================================

  /// Fetches all active sessions for a specific user from Supabase,
  /// automatically enforcing the 7-day auto-deletion policy.
  /// Fetches all sessions for a user from Supabase.
  /// Enforces 7-day auto-deletion policy ONLY for completed sessions whose inputs were kept.
  /// Unfinished sessions are NEVER auto-deleted without user confirmation.
  Future<List<SavedInput>> fetchUserSessions(String userId) async {
    try {
      final userFilter = userId.trim().isNotEmpty
          ? 'or=(user_id.eq.$userId,user_id.is.null)&'
          : '';
      final uri = Uri.parse(
        '$supabaseUrl/rest/v1/sessions?${userFilter}order=start_time.desc',
      );
      final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return [];
      }

      final List<dynamic> data = jsonDecode(response.body);
      final List<SavedInput> rawList = [];
      final now = DateTime.now();

      for (int i = 0; i < data.length; i++) {
        final row = data[i];
        final sessionId = row['session_id'] as String;
        final isNotesGenerated = row['notes_generated'] as bool? ?? false;
        final rawExpires = row['expires_at'] as String?;
        DateTime? expiresAt;
        if (rawExpires != null) {
          expiresAt = DateTime.tryParse(rawExpires);
        }

        // Scenario 1 requirement: 7-day automatic deletion ONLY for completed sessions
        // whose inputs were retained. Unfinished sessions must NEVER auto-delete!
        if (isNotesGenerated && expiresAt != null && now.isAfter(expiresAt)) {
          discardSessionInputs(sessionId);
          continue;
        }

        final rawCreated = row['start_time'] as String?;
        final createdAt = rawCreated != null ? DateTime.tryParse(rawCreated) : null;
        final baseEpoch = createdAt != null ? (createdAt.millisecondsSinceEpoch / 1000.0) : null;

        // Fetch associated chunks and snapshots together
        final lines = await _fetchSessionChunks(sessionId, baseEpoch: baseEpoch);
        final images = await _fetchSessionImages(sessionId, baseEpoch: baseEpoch);

        // If notes have been generated and raw inputs were discarded (no chunks and no images),
        // then this session has no inputs to show in Saved Inputs (its document is in Saved Notes).
        if (isNotesGenerated && lines.isEmpty && images.isEmpty && (row['raw_content'] == null || (row['raw_content'] as String).isEmpty)) {
          continue;
        }

        rawList.add(
          SavedInput(
            id: i + 1,
            sessionId: sessionId,
            userId: row['user_id'] as String? ?? userId,
            title: row['title'] as String? ?? 'Untitled Session',
            type: row['input_type'] as String? ?? 'Workshop Session',
            content: row['raw_content'] as String? ?? '',
            notesGenerated: isNotesGenerated,
            audioDuration: row['audio_duration'] as String?,
            expiresAt: expiresAt,
            createdAt: createdAt,
            transcriptLines: lines,
            capturedImages: images,
            audioTranscripts: lines.map((l) => l.formatted).toList(),
          ),
        );
      }

      // Scenario 3: Group all inputs belonging to the same session ID
      // Each session displays its associated images and audio recordings together.
      final Map<String, SavedInput> grouped = {};
      for (final input in rawList) {
        if (grouped.containsKey(input.sessionId)) {
          final existing = grouped[input.sessionId]!;
          // Merge transcript lines without duplicates
          for (final l in input.transcriptLines) {
            if (!existing.transcriptLines.any((e) => e.id == l.id)) {
              existing.transcriptLines.add(l);
            }
          }
          // Merge captured images without duplicates
          for (final img in input.capturedImages) {
            if (!existing.capturedImages.any((e) => e.snapshotId == img.snapshotId && e.id == img.id)) {
              existing.capturedImages.add(img);
            }
          }
          // Sort chronologically
          existing.transcriptLines.sort((a, b) => a.secondTrigger.compareTo(b.secondTrigger));
          existing.capturedImages.sort((a, b) => (a.capturedAtSecond ?? 0).compareTo(b.capturedAtSecond ?? 0));
          existing.audioTranscripts = existing.transcriptLines.map((l) => l.formatted).toList();
        } else {
          // Sort initial inputs chronologically
          input.transcriptLines.sort((a, b) => a.secondTrigger.compareTo(b.secondTrigger));
          input.capturedImages.sort((a, b) => (a.capturedAtSecond ?? 0).compareTo(b.capturedAtSecond ?? 0));
          grouped[input.sessionId] = input;
        }
      }

      return grouped.values.toList();
    } catch (e) {
      return [];
    }
  }

  /// Normalizes a timestamp (handling both epoch seconds and relative seconds)
  int _normalizeTimestamp(double rawTs, double? baseEpoch) {
    if (rawTs > 1000000000) {
      if (baseEpoch != null && baseEpoch > 1000000000) {
        final diff = (rawTs - baseEpoch).round();
        return diff >= 0 ? diff : 0;
      }
      return 0;
    }
    return rawTs.round();
  }

  Future<List<TranscriptLineItem>> _fetchSessionChunks(String sessionId, {double? baseEpoch}) async {
    try {
      final uri = Uri.parse(
        '$supabaseUrl/rest/v1/audio_chunks?session_id=eq.$sessionId&order=start_timestamp.asc',
      );
      final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return [];

      final List<dynamic> chunks = jsonDecode(response.body);
      if (chunks.isEmpty) return [];

      // If baseEpoch is unknown and first chunk uses epoch seconds, use first chunk as base
      double? effectiveBase = baseEpoch;
      final firstRawTs = (chunks.first['start_timestamp'] as num?)?.toDouble() ?? 0.0;
      if (firstRawTs > 1000000000 && (effectiveBase == null || effectiveBase < 1000000000)) {
        effectiveBase = firstRawTs;
      }

      return chunks.map((c) {
        final rawTs = (c['start_timestamp'] as num?)?.toDouble() ?? 0.0;
        final sec = _normalizeTimestamp(rawTs, effectiveBase);
        final mins = (sec ~/ 60).toString().padLeft(2, '0');
        final secs = (sec % 60).toString().padLeft(2, '0');
        return TranscriptLineItem(
          id: c['chunk_id'] as String? ?? 'chunk_${DateTime.now().millisecondsSinceEpoch}',
          timestamp: '$mins:$secs',
          text: c['transcript_text'] as String? ?? '',
          isFlagged: c['is_flagged_noise'] as bool? ?? false,
          flagReason: c['noise_reason'] as String? ?? '',
          secondTrigger: sec,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<CapturedImageItem>> _fetchSessionImages(String sessionId, {double? baseEpoch}) async {
    try {
      final uri = Uri.parse(
        '$supabaseUrl/rest/v1/image_snapshots?session_id=eq.$sessionId&order=timestamp.asc',
      );
      final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return [];

      final List<dynamic> snapshots = jsonDecode(response.body);
      final List<CapturedImageItem> items = [];

      for (int i = 0; i < snapshots.length; i++) {
        final s = snapshots[i];
        final snapId = s['snapshot_id'] as String;
        final rawTs = (s['timestamp'] as num?)?.toDouble() ?? 0.0;
        final sec = _normalizeTimestamp(rawTs, baseEpoch);
        final prefStr = s['note_inclusion_preference'] as String? ?? 'BOTH';
        final pref = prefStr == 'IMAGE_ONLY'
            ? BoardImageOption.imageAsIs
            : prefStr == 'OCR_TEXT_ONLY'
                ? BoardImageOption.ocr
                : BoardImageOption.both;

        // Fetch OCR text if available
        String ocrText = '';
        double? confidence;
        try {
          final ocrUri = Uri.parse(
            '$supabaseUrl/rest/v1/ocr_extractions?snapshot_id=eq.$snapId&limit=1',
          );
          final ocrResp = await http.get(ocrUri, headers: _headers).timeout(const Duration(seconds: 5));
          if (ocrResp.statusCode == 200) {
            final List<dynamic> ocrData = jsonDecode(ocrResp.body);
            if (ocrData.isNotEmpty) {
              ocrText = ocrData[0]['extracted_text'] as String? ?? '';
              confidence = (ocrData[0]['confidence_score'] as num?)?.toDouble();
            }
          }
        } catch (_) {}

        final filepath = s['blurred_filepath'] as String? ?? '';
        items.add(
          CapturedImageItem(
            id: i + 1,
            title: 'Board Capture #${i + 1}',
            ocrText: ocrText,
            option: pref,
            capturedAtSecond: sec,
            remoteImageUrl: filepath.startsWith('http') ? filepath : null,
            localImagePath: !filepath.startsWith('http') ? filepath : null,
            snapshotId: snapId,
            confidenceScore: confidence,
          ),
        );
      }
      return items;
    } catch (_) {
      return [];
    }
  }

  /// Saves a session and its transcript lines + snapshots into Supabase PostgreSQL tables.
  Future<bool> saveSession({
    required SavedInput input,
  }) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/sessions');
      final payload = {
        'session_id': input.sessionId,
        'user_id': input.userId,
        'title': input.title,
        'start_time': input.createdAt.toIso8601String(),
        'status': 'COMPLETED',
        'notes_generated': input.notesGenerated,
        'expires_at': input.expiresAt?.toIso8601String(),
        'raw_content': input.content,
        'audio_duration': input.audioDuration,
        'input_type': input.type,
      };

      final response = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 12));

      // Persist audio chunk lines to audio_chunks table
      if (input.transcriptLines.isNotEmpty) {
        await _persistChunks(input.sessionId, input.transcriptLines);
      }

      // Persist image snapshots & OCR text
      if (input.capturedImages.isNotEmpty) {
        await _persistImages(input.sessionId, input.capturedImages);
      }

      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      return false;
    }
  }

  Future<void> _persistChunks(String sessionId, List<TranscriptLineItem> lines) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/audio_chunks');
      final chunksPayload = lines.map((l) {
        final uniqueChunkId = l.id.isNotEmpty && !l.id.startsWith('chunk_')
            ? l.id
            : 'chunk_${sessionId}_${l.secondTrigger}_${DateTime.now().millisecondsSinceEpoch}_${lines.indexOf(l)}';
        return {
          'chunk_id': uniqueChunkId,
          'session_id': sessionId,
          'start_timestamp': l.secondTrigger.toDouble(),
          'end_timestamp': (l.secondTrigger + 5).toDouble(),
          'audio_filepath': 'supabase_audio_$uniqueChunkId',
          'transcript_text': l.text,
          'is_flagged_noise': l.isFlagged,
          'noise_reason': l.flagReason,
          'user_override_status': l.isFlagged ? 'PENDING' : 'KEEP',
        };
      }).toList();

      await http.post(
        uri,
        headers: _headers,
        body: jsonEncode(chunksPayload),
      );
    } catch (_) {}
  }

  Future<void> _persistImages(String sessionId, List<CapturedImageItem> images) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/image_snapshots');
      for (int i = 0; i < images.length; i++) {
        final img = images[i];
        final snapId = img.snapshotId ?? 'snap_${sessionId}_${img.id}_$i';
        final payload = {
          'snapshot_id': snapId,
          'session_id': sessionId,
          'timestamp': (img.capturedAtSecond ?? 0).toDouble(),
          'blurred_filepath': img.remoteImageUrl ?? img.localImagePath ?? 'local_capture',
          'note_inclusion_preference': img.option == BoardImageOption.imageAsIs
              ? 'IMAGE_ONLY'
              : img.option == BoardImageOption.ocr
                  ? 'OCR_TEXT_ONLY'
                  : 'BOTH',
        };
        await http.post(uri, headers: _headers, body: jsonEncode(payload));

        // Also persist OCR extraction if present
        if (img.ocrText.isNotEmpty) {
          final ocrUri = Uri.parse('$supabaseUrl/rest/v1/ocr_extractions');
          final ocrPayload = {
            'ocr_id': 'ocr_$snapId',
            'snapshot_id': snapId,
            'session_id': sessionId,
            'extracted_text': img.ocrText,
            'confidence_score': img.confidenceScore ?? 0.95,
          };
          await http.post(ocrUri, headers: _headers, body: jsonEncode(ocrPayload));
        }
      }
    } catch (_) {}
  }

  /// Updates session metadata in Supabase.
  Future<bool> updateSession({
    required String sessionId,
    String? title,
    String? rawContent,
    bool? notesGenerated,
  }) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/sessions?session_id=eq.$sessionId');
      final Map<String, dynamic> payload = {};
      if (title != null) payload['title'] = title;
      if (rawContent != null) payload['raw_content'] = rawContent;
      if (notesGenerated != null) payload['notes_generated'] = notesGenerated;

      if (payload.isEmpty) return true;

      final response = await http.patch(
        uri,
        headers: _headers,
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  /// Updates an individual audio chunk line (e.g. user corrected text or unflagged noise).
  Future<bool> updateAudioChunk({
    required String chunkId,
    required String text,
    required bool isFlagged,
    String? noiseReason,
  }) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/audio_chunks?chunk_id=eq.$chunkId');
      final payload = {
        'transcript_text': text,
        'is_flagged_noise': isFlagged,
        'user_override_status': isFlagged ? 'PENDING' : 'KEEP',
      };
      if (noiseReason != null) payload['noise_reason'] = noiseReason;

      final response = await http.patch(
        uri,
        headers: _headers,
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  /// Deletes an individual audio chunk from Supabase.
  Future<bool> deleteAudioChunk(String chunkId) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/audio_chunks?chunk_id=eq.$chunkId');
      final response = await http.delete(uri, headers: _headers).timeout(const Duration(seconds: 10));
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  /// Updates board image snapshot preference in Supabase.
  Future<bool> updateImageSnapshotPreference({
    required String snapshotId,
    required BoardImageOption option,
  }) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/image_snapshots?snapshot_id=eq.$snapshotId');
      final payload = {
        'note_inclusion_preference': option == BoardImageOption.imageAsIs
            ? 'IMAGE_ONLY'
            : option == BoardImageOption.ocr
                ? 'OCR_TEXT_ONLY'
                : 'BOTH',
      };
      final response = await http.patch(uri, headers: _headers, body: jsonEncode(payload));
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  /// Deletes an image snapshot from Supabase.
  Future<bool> deleteImageSnapshot(String snapshotId) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/image_snapshots?snapshot_id=eq.$snapshotId');
      final response = await http.delete(uri, headers: _headers).timeout(const Duration(seconds: 10));
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  /// Helper to delete objects from Supabase storage buckets
  Future<void> _deleteStorageObjects(String bucket, List<String> prefixes) async {
    try {
      final uri = Uri.parse('$supabaseUrl/storage/v1/object/$bucket');
      await http.delete(
        uri,
        headers: _headers,
        body: jsonEncode({'prefixes': prefixes}),
      ).timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  /// Scenario 1: Discard Inputs
  /// Permanently deletes session inputs (audio chunks, containers, snapshots, storage files)
  /// from Supabase while preserving the generated note intact in generated_notes table.
  Future<bool> discardSessionInputs(String sessionId) async {
    try {
      // 1. Delete all audio chunks for this session
      final chunksUri = Uri.parse('$supabaseUrl/rest/v1/audio_chunks?session_id=eq.$sessionId');
      await http.delete(chunksUri, headers: _headers).timeout(const Duration(seconds: 8));

      // 2. Delete all audio containers
      final contUri = Uri.parse('$supabaseUrl/rest/v1/audio_containers?session_id=eq.$sessionId');
      await http.delete(contUri, headers: _headers).timeout(const Duration(seconds: 8));

      // 3. Delete OCR extractions & image snapshots
      final ocrUri = Uri.parse('$supabaseUrl/rest/v1/ocr_extractions?session_id=eq.$sessionId');
      await http.delete(ocrUri, headers: _headers).timeout(const Duration(seconds: 8));

      final snapsUri = Uri.parse('$supabaseUrl/rest/v1/image_snapshots?session_id=eq.$sessionId');
      await http.delete(snapsUri, headers: _headers).timeout(const Duration(seconds: 8));

      // 4. Delete audio files from Supabase Storage
      await _deleteStorageObjects('lecture-audio', ['$sessionId/']);
      await _deleteStorageObjects('lecture-slides', ['public/$sessionId', sessionId]);

      // 5. Update session row: mark notes_generated = true, raw inputs cleared, expiry cleared
      final sessUri = Uri.parse('$supabaseUrl/rest/v1/sessions?session_id=eq.$sessionId');
      final updatePayload = {
        'notes_generated': true,
        'raw_content': null,
        'expires_at': null,
        'status': 'COMPLETED',
      };
      await http.patch(sessUri, headers: _headers, body: jsonEncode(updatePayload)).timeout(const Duration(seconds: 8));

      return true;
    } catch (_) {
      return false;
    }
  }

  /// Scenario 1: Keep Inputs
  /// Retains session inputs temporarily for 7 days (expires_at = now + 7 days).
  Future<bool> keepSessionInputs(String sessionId, {int days = 7}) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/sessions?session_id=eq.$sessionId');
      final expiresAt = DateTime.now().add(Duration(days: days));
      final payload = {
        'notes_generated': true,
        'expires_at': expiresAt.toIso8601String(),
        'status': 'COMPLETED',
      };
      final response = await http.patch(
        uri,
        headers: _headers,
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 8));

      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  /// Permanently deletes a session and all its inputs from Supabase.
  /// Generated notes remain completely intact because session_id is ON DELETE SET NULL.
  Future<bool> deleteSession(String sessionId) async {
    try {
      // Purge inputs and storage first
      await discardSessionInputs(sessionId);

      // Delete the session row itself
      final uri = Uri.parse('$supabaseUrl/rest/v1/sessions?session_id=eq.$sessionId');
      final response = await http.delete(uri, headers: _headers).timeout(const Duration(seconds: 10));
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  /// Scenario 2: Enforce maximum of 2 unfinished sessions per user
  Future<int> countUnfinishedSessions(String userId) async {
    try {
      final userFilter = userId.trim().isNotEmpty
          ? 'or=(user_id.eq.$userId,user_id.is.null)&'
          : '';
      final uri = Uri.parse(
        '$supabaseUrl/rest/v1/sessions?${userFilter}notes_generated=eq.false&select=session_id',
      );
      final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.length;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }

  // ===========================================================================
  // GENERATED NOTES (FETCH, INSERT, UPDATE, DELETE)
  // ===========================================================================

  /// Fetches all generated notes for a user from Supabase.
  Future<List<DemoNote>> fetchUserNotes(String userId) async {
    try {
      final userFilter = userId.trim().isNotEmpty
          ? 'or=(user_id.eq.$userId,user_id.is.null)&'
          : '';
      final uri = Uri.parse('$supabaseUrl/rest/v1/generated_notes?${userFilter}order=created_at.desc');
      final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return [];

      final List<dynamic> data = jsonDecode(response.body);
      final List<DemoNote> notes = [];

      for (int i = 0; i < data.length; i++) {
        final row = data[i];
        final rawCreated = row['created_at'] as String?;
        final createdAt = rawCreated != null ? DateTime.tryParse(rawCreated) : null;

        notes.add(
          DemoNote(
            id: i + 1,
            noteId: row['note_id'] as String?,
            sessionId: row['session_id'] as String?,
            userId: row['user_id'] as String?,
            title: row['title'] as String? ?? 'Untitled Note',
            content: row['markdown_content'] as String? ?? '',
            type: 'Workshop Session Notes',
            isSatisfactory: row['is_satisfactory'] as bool?,
            createdAt: createdAt,
          ),
        );
      }

      return notes;
    } catch (_) {
      return [];
    }
  }

  /// Saves the final generated notes in generated_notes table.
  Future<bool> saveGeneratedNote({
    required String sessionId,
    required String userId,
    required DemoNote note,
    required bool isSatisfactory,
  }) async {
    try {
      final noteId = note.noteId ?? 'note_${note.id}_${DateTime.now().millisecondsSinceEpoch}';
      note.noteId = noteId;
      note.sessionId = sessionId;
      note.userId = userId;
      note.isSatisfactory = isSatisfactory;

      final uri = Uri.parse('$supabaseUrl/rest/v1/generated_notes');
      final payload = {
        'note_id': noteId,
        'session_id': sessionId,
        'user_id': userId,
        'title': note.title,
        'markdown_content': note.content,
        'is_satisfactory': isSatisfactory,
      };

      final response = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200 || response.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  /// Updates note title and content in Supabase generated_notes table.
  Future<bool> updateGeneratedNote({
    required String noteId,
    required String title,
    required String content,
  }) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/generated_notes?note_id=eq.$noteId');
      final payload = {
        'title': title,
        'markdown_content': content,
      };
      final response = await http.patch(
        uri,
        headers: _headers,
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  /// Permanently deletes a note from Supabase generated_notes table.
  Future<bool> deleteGeneratedNote(String noteId) async {
    try {
      final uri = Uri.parse('$supabaseUrl/rest/v1/generated_notes?note_id=eq.$noteId');
      final response = await http.delete(uri, headers: _headers).timeout(const Duration(seconds: 10));
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }
}
