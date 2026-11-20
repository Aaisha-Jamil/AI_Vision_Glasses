import 'package:flutter/foundation.dart';
import '../models/board_image_item.dart';
import '../models/note.dart';
import '../models/saved_input.dart';
import '../models/transcript_line_item.dart';
import '../services/notes_service.dart';
import '../services/supabase_service.dart';
import '../services/vision_service.dart';

class NotesGenerationException implements Exception {
  NotesGenerationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DemoData {
  static final List<SavedInput> savedInputs = [];
  static int nextInputId = 1;
  static String currentUserId = 'user_demo@aivision.com';

  static final List<DemoNote> notes = [];
  static int nextId = 1;
  static final ValueNotifier<int> noteCount = ValueNotifier<int>(0);

  static bool isSyncing = false;

  /// Scenario 2: Maximum of 2 unfinished sessions can be saved per user.
  static const int maxUnfinishedSessions = 2;

  /// Number of active sessions stored that do not have generated notes yet.
  static int get unfinishedSessionCount =>
      savedInputs.where((s) => !s.notesGenerated).length;

  /// Whether the user is permitted to store another new unfinished session.
  static bool get canAddUnfinishedSession => unfinishedSessionCount < maxUnfinishedSessions;

  // Compatibility aliases
  static const int maxUnnotedSessions = maxUnfinishedSessions;
  static int get unnotedSessionCount => unfinishedSessionCount;
  static bool get canAddSession => canAddUnfinishedSession;

  static void refreshCount() {
    noteCount.value = notes.length;
  }

  /// Loads previously saved sessions and notes from Supabase for [userId] (or [currentUserId]).
  /// Ensures all user data remains persistent after refreshing or restarting the application.
  static Future<void> loadFromSupabase([String? userId]) async {
    if (userId != null && userId.trim().isNotEmpty) {
      currentUserId = userId.trim();
    }
    isSyncing = true;
    try {
      final supa = SupabaseService();
      // 1. Fetch sessions
      final remoteSessions = await supa.fetchUserSessions(currentUserId);
      if (remoteSessions.isNotEmpty) {
        savedInputs.clear();
        savedInputs.addAll(remoteSessions);
        int maxInputId = 0;
        for (final s in remoteSessions) {
          if (s.id > maxInputId) maxInputId = s.id;
        }
        nextInputId = maxInputId + 1;
      }

      // 2. Fetch notes
      final remoteNotes = await supa.fetchUserNotes(currentUserId);
      if (remoteNotes.isNotEmpty) {
        notes.clear();
        notes.addAll(remoteNotes);
        int maxNoteId = 0;
        for (final n in remoteNotes) {
          if (n.id > maxNoteId) maxNoteId = n.id;
        }
        nextId = maxNoteId + 1;
      }
      refreshCount();

      // 3. User sessions loaded from Supabase. If none exist yet,
      //    savedInputs remains empty until the user records a real session.
    } catch (_) {
      // Offline fallback: keep existing local sessions
    } finally {
      isSyncing = false;
    }
  }

  /// Seeds a rich sample Workshop Session card so the user always has a card
  /// to tap "Studio View" on, even before recording their own session.
  static void _seedSampleWorkshopSession() {
    final sampleLines = [
      TranscriptLineItem(
        id: 'sample_chunk_1',
        timestamp: '00:00',
        text: 'Welcome to today\'s lecture on Neural Network Architectures.',
        isFlagged: false,
        flagReason: '',
        secondTrigger: 0,
      ),
      TranscriptLineItem(
        id: 'sample_chunk_2',
        timestamp: '00:15',
        text: 'We will be covering convolutional layers, pooling, and activation functions.',
        isFlagged: false,
        flagReason: '',
        secondTrigger: 15,
      ),
      TranscriptLineItem(
        id: 'sample_chunk_3',
        timestamp: '00:32',
        text: '[cough] ... sorry about that. As I was saying, the ReLU activation is widely used.',
        isFlagged: true,
        flagReason: 'Background noise detected',
        secondTrigger: 32,
      ),
      TranscriptLineItem(
        id: 'sample_chunk_4',
        timestamp: '01:05',
        text: 'Let me draw the architecture diagram on the board now.',
        isFlagged: false,
        flagReason: '',
        secondTrigger: 65,
      ),
      TranscriptLineItem(
        id: 'sample_chunk_5',
        timestamp: '01:45',
        text: 'This is the input layer feeding into 3 convolutional layers with 64, 128, and 256 filters.',
        isFlagged: false,
        flagReason: '',
        secondTrigger: 105,
      ),
    ];

    final sampleImages = [
      CapturedImageItem(
        id: 1,
        title: 'Board Capture #1 — Architecture Diagram',
        ocrText: 'Input Layer → Conv2D(64) → MaxPool → Conv2D(128) → MaxPool → Conv2D(256) → Flatten → Dense(512) → Output',
        option: BoardImageOption.both,
        capturedAtSecond: 70,
        snapshotId: 'sample_snap_1',
      ),
      CapturedImageItem(
        id: 2,
        title: 'Board Capture #2 — Loss Function',
        ocrText: 'Loss = -Σ y_i · log(ŷ_i)  (Cross-Entropy Loss)\nOptimizer: Adam, lr=0.001',
        option: BoardImageOption.both,
        capturedAtSecond: 120,
        snapshotId: 'sample_snap_2',
      ),
    ];

    final input = SavedInput(
      id: nextInputId++,
      sessionId: 'sample_session_demo',
      userId: currentUserId,
      title: 'Neural Networks Architecture Lecture',
      type: 'Workshop Session',
      content: 'Sample Workshop Lecture Session\nDuration: 02:30\nTranscripts: 5 lines\nBoard captures: 2 images',
      capturedImages: sampleImages,
      audioTranscripts: sampleLines.map((l) => l.formatted).toList(),
      transcriptLines: sampleLines,
      audioDuration: '02:30',
    );
    savedInputs.insert(0, input);
  }

  /// Scenario 1: Automatically clears completed sessions that have passed their 7-day retention window.
  /// Scenario 2: Unfinished sessions are NEVER automatically deleted without user confirmation!
  static void cleanExpiredSessions() {
    final now = DateTime.now();
    final expired = savedInputs.where((s) => s.notesGenerated && s.expiresAt != null && now.isAfter(s.expiresAt!)).toList();
    for (final s in expired) {
      savedInputs.remove(s);
      SupabaseService().discardSessionInputs(s.sessionId);
    }
  }

  static SavedInput addInput({
    required String title,
    required String type,
    required String content,
    String? sessionId,
    String? userId,
    List<CapturedImageItem> capturedImages = const [],
    List<String> audioTranscripts = const [],
    String? audioDuration,
  }) {
    final sid = sessionId ?? 'sess_${DateTime.now().millisecondsSinceEpoch}';
    final uid = userId ?? currentUserId;

    // Check if session already exists for this sessionId
    final existingIdx = savedInputs.indexWhere((s) => s.sessionId == sid);
    if (existingIdx >= 0) {
      final existing = savedInputs[existingIdx];
      existing.title = title;
      existing.type = type;
      existing.content = content;
      if (capturedImages.isNotEmpty) {
        existing.capturedImages = List.from(capturedImages);
      }
      if (audioTranscripts.isNotEmpty) {
        existing.audioTranscripts = List.from(audioTranscripts);
      }
      if (audioDuration != null) {
        existing.audioDuration = audioDuration;
      }
      SupabaseService().saveSession(input: existing);
      return existing;
    }

    final input = SavedInput(
      id: nextInputId++,
      sessionId: sid,
      userId: uid,
      title: title,
      type: type,
      content: content,
      capturedImages: List.from(capturedImages),
      audioTranscripts: List.from(audioTranscripts),
      audioDuration: audioDuration,
    );
    savedInputs.insert(0, input);

    // Persist to Supabase
    SupabaseService().saveSession(input: input);

    return input;
  }

  static SavedInput addSessionInput({
    required String title,
    required List<String> audioTranscripts,
    required List<CapturedImageItem> capturedImages,
    required String audioDuration,
    String? sessionId,
    String? userId,
    List<TranscriptLineItem>? allTranscriptLines,
  }) {
    final sid = sessionId ?? 'sess_${DateTime.now().millisecondsSinceEpoch}';
    final uid = userId ?? currentUserId;

    // If this session already exists (e.g. user reopened/resumed an existing session),
    // update the session in place instead of creating a duplicate!
    final existingIdx = savedInputs.indexWhere((s) => s.sessionId == sid);
    if (existingIdx >= 0) {
      final existing = savedInputs[existingIdx];
      existing.title = title;
      existing.audioDuration = audioDuration;
      existing.audioTranscripts = List.from(audioTranscripts);
      existing.capturedImages = List.from(capturedImages);
      if (allTranscriptLines != null) {
        existing.transcriptLines = List.from(allTranscriptLines);
      }
      // Re-persist updated session to Supabase
      SupabaseService().saveSession(input: existing);
      return existing;
    }

    final buffer = StringBuffer();
    buffer.writeln('Workshop Lecture Session: $title');
    buffer.writeln('Recording duration: $audioDuration');
    buffer.writeln('Transcripts recorded: ${audioTranscripts.length}');
    buffer.writeln('Board images captured: ${capturedImages.length}');

    final input = SavedInput(
      id: nextInputId++,
      sessionId: sid,
      userId: uid,
      title: title,
      type: 'Workshop Session',
      content: buffer.toString(),
      capturedImages: List.from(capturedImages),
      audioTranscripts: List.from(audioTranscripts),
      transcriptLines: allTranscriptLines != null
          ? List.from(allTranscriptLines)
          : [],
      audioDuration: audioDuration,
    );
    savedInputs.insert(0, input);

    // Persist session & chunks & snapshots to Supabase
    SupabaseService().saveSession(input: input);

    return input;
  }

  static bool deleteInput(int id) {
    final index = savedInputs.indexWhere((element) => element.id == id);
    if (index != -1) {
      final input = savedInputs.removeAt(index);
      SupabaseService().deleteSession(input.sessionId);
      return true;
    }
    return false;
  }

  /// Syncs an edited transcript line to Supabase PostgreSQL table audio_chunks.
  static Future<bool> updateTranscriptLine(TranscriptLineItem line) async {
    return await SupabaseService().updateAudioChunk(
      chunkId: line.id,
      text: line.text,
      isFlagged: line.isFlagged,
      noiseReason: line.flagReason,
    );
  }

  /// Deletes a transcript line from Supabase PostgreSQL table audio_chunks.
  static Future<bool> deleteTranscriptLine(TranscriptLineItem line) async {
    return await SupabaseService().deleteAudioChunk(line.id);
  }

  static DemoNote? generateNotesForInput(SavedInput input) {
    if (input.notesGenerated) return null;

    DemoNote newNote;
    if (input.type == 'Workshop Session') {
      final buffer = StringBuffer();
      buffer.writeln('=== WORKSHOP LECTURE SUMMARY ===');
      buffer.writeln('Session: ${input.title}');
      buffer.writeln('User ID: ${input.userId}');
      buffer.writeln('Session ID: ${input.sessionId}');
      if (input.audioDuration != null) {
        buffer.writeln('Duration: ${input.audioDuration}\n');
      }

      buffer.writeln('--- Audio Lecture Transcripts ---');
      if (input.audioTranscripts.isNotEmpty) {
        for (final line in input.audioTranscripts) {
          buffer.writeln(line);
        }
      } else if (input.transcriptLines.isNotEmpty) {
        for (final line in input.transcriptLines) {
          if (!line.isFlagged) {
            buffer.writeln('[${line.timestamp}] ${line.text}');
          }
        }
      } else if (input.content.trim().isNotEmpty) {
        buffer.writeln(input.content.trim());
      } else {
        buffer.writeln('No audio transcripts captured.');
      }

      buffer.writeln('\n--- Board Captures & Extracted Knowledge ---');
      if (input.capturedImages.isNotEmpty) {
        for (var i = 0; i < input.capturedImages.length; i++) {
          final img = input.capturedImages[i];
          buffer.writeln('Capture #${i + 1}: ${img.title} [Mode: ${img.option.label}]');
          if (img.option != BoardImageOption.imageAsIs) {
            buffer.writeln('OCR Text:\n${img.ocrText.trim()}');
          }
          if (img.option == BoardImageOption.imageAsIs) {
            buffer.writeln('(Visual board graphic saved with raw capture data)');
          }
          buffer.writeln('');
        }
      } else {
        buffer.writeln('No board images attached.');
      }

      buffer.writeln('--- Key Action Items & Concepts ---');
      buffer.writeln('• Review core architectural components outlined on board.');
      buffer.writeln('• Cross-reference audio highlights with board diagram equations.');
      buffer.writeln('• Prepare follow-up questions for next lecture.');

      newNote = addNote(
        title: '${input.title} - Comprehensive Notes',
        content: buffer.toString(),
        type: 'Workshop Session Notes',
        sessionId: input.sessionId,
        userId: input.userId,
      );
    } else {
      newNote = addNote(
        title: '${input.title} Notes',
        content: input.content,
        type: input.type,
        sessionId: input.sessionId,
        userId: input.userId,
      );
    }

    input.notesGenerated = true;
    return newNote;
  }

  /// Generates academic lecture notes for [input] through the backend (Gemini).
  /// Returns null if notes were already generated for it; throws
  /// [NotesGenerationException] with the reason if generation fails.
  static Future<DemoNote?> generateAiNotesForInput(SavedInput input) async {
    if (input.notesGenerated) return null;

    // OCR text that arrived after this copy was saved (the server also waits for
    // still-running OCR and fills it in, so a placeholder never reaches the notes)
    VisionService.applyKnownOcr(input.capturedImages);

    final sessionData = {
      'session_id': input.sessionId,
      'title': input.title,
      'user_id': input.userId,
      'audio_duration': input.audioDuration,
      'audio_chunks': input.transcriptLines.isNotEmpty
          ? input.transcriptLines
              .map((l) => {
                    'chunk_id': l.id,
                    'start_timestamp': l.secondTrigger.toDouble(),
                    'end_timestamp': (l.secondTrigger + 5).toDouble(),
                    'transcript_text': l.text,
                    'edited_text': l.text,
                    'is_flagged_noise': l.isFlagged,
                    'user_override_status': l.isFlagged ? 'PENDING' : 'KEEP',
                  })
              .toList()
          : (input.audioTranscripts.isNotEmpty
              ? input.audioTranscripts
              : (input.content.trim().isNotEmpty ? [input.content.trim()] : [])),
      'image_snapshots': input.capturedImages
          .map((img) => {
                'snapshot_id': img.snapshotId ?? 'snap_${img.id}',
                'sequence_timestamp': (img.capturedAtSecond ?? 0).toDouble(),
                'captured_timestamp': (img.capturedAtSecond ?? 0).toDouble(),
                'blurred_image_url': img.remoteImageUrl ?? img.localImagePath ?? '',
                'note_inclusion_preference': img.option == BoardImageOption.imageAsIs
                    ? 'IMAGE_ONLY'
                    : img.option == BoardImageOption.ocr
                        ? 'OCR_TEXT_ONLY'
                        : 'BOTH',
                'ocr_text': img.ocrText,
                'confidence_score': img.confidenceScore ?? 0.95,
              })
          .toList(),
    };

    final res = await NotesService().generateNotes(
      sessionId: input.sessionId,
      userId: input.userId,
      sessionData: sessionData,
    );

    final markdown = res['markdown_content'];
    if (res['status'] != 'success' || markdown is! String || markdown.trim().isEmpty) {
      // No silent local fallback: template notes looked like real AI notes.
      throw NotesGenerationException(
        (res['message'] ?? 'Notes generation failed.').toString(),
      );
    }
    final docxUrl = (res['docx_url'] as String?) ?? (res['docx_path'] as String?);

    final newNote = addNote(
      title: '${input.title} - Comprehensive Notes',
      content: markdown,
      type: 'Workshop Session Notes',
      sessionId: input.sessionId,
      userId: input.userId,
      docxUrl: docxUrl,
    );

    input.notesGenerated = true;
    return newNote;
  }

  /// Scenario 1: Applies retention decision after document has been generated:
  /// - If [discardInputs] is true (or [deleteNow] is true): Permanently deletes the raw session
  ///   inputs from Supabase, while ensuring the generated document in Saved Notes is completely preserved.
  /// - If [discardInputs] is false: Retains the inputs temporarily with a 7-day auto-delete expiry.
  static void applyRetentionDecision(
    SavedInput input, {
    bool? discardInputs,
    bool deleteNow = false,
    bool isSatisfactory = true,
    DemoNote? note,
  }) {
    final shouldDiscard = discardInputs ?? deleteNow;
    input.isSatisfactory = isSatisfactory;
    input.notesGenerated = true;

    // 1. Ensure note is saved in Supabase generated_notes table
    if (note != null) {
      SupabaseService().saveGeneratedNote(
        sessionId: input.sessionId,
        userId: input.userId,
        note: note,
        isSatisfactory: isSatisfactory,
      );
    }

    if (shouldDiscard) {
      // Discard raw inputs from local state
      savedInputs.removeWhere((s) => s.sessionId == input.sessionId || s.id == input.id);
      // Discard raw inputs from Supabase DB & Storage (generated notes are NOT affected!)
      SupabaseService().discardSessionInputs(input.sessionId);
    } else {
      // Retain inputs for 7 days
      final expiry = DateTime.now().add(const Duration(days: 7));
      input.expiresAt = expiry;
      SupabaseService().keepSessionInputs(input.sessionId, days: 7);
    }
  }

  static DemoNote addNote({
    required String title,
    required String content,
    required String type,
    String? sessionId,
    String? userId,
    String? docxUrl,
  }) {
    final sid = sessionId ?? 'sess_direct_${DateTime.now().millisecondsSinceEpoch}';
    final uid = userId ?? currentUserId;
    final noteId = 'note_${nextId}_${DateTime.now().millisecondsSinceEpoch}';

    final note = DemoNote(
      id: nextId++,
      noteId: noteId,
      sessionId: sid,
      userId: uid,
      title: title,
      content: content,
      type: type,
      docxUrl: docxUrl,
    );
    notes.insert(0, note);
    refreshCount();

    // Persist note to Supabase generated_notes
    SupabaseService().saveGeneratedNote(
      sessionId: sid,
      userId: uid,
      note: note,
      isSatisfactory: true,
    );

    return note;
  }

  /// Updates an existing note locally and in Supabase generated_notes table.
  static Future<bool> updateNote(DemoNote note) async {
    refreshCount();
    if (note.noteId != null && note.noteId!.isNotEmpty) {
      return await SupabaseService().updateGeneratedNote(
        noteId: note.noteId!,
        title: note.title,
        content: note.content,
      );
    }
    return true;
  }

  /// Deletes a note locally and permanently removes it from Supabase.
  static Future<bool> deleteNote(int id) async {
    final index = notes.indexWhere((n) => n.id == id);
    if (index != -1) {
      final note = notes.removeAt(index);
      refreshCount();
      if (note.noteId != null && note.noteId!.isNotEmpty) {
        return await SupabaseService().deleteGeneratedNote(note.noteId!);
      }
      return true;
    }
    return false;
  }
}
