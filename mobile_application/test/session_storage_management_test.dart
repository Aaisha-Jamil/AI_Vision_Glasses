import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_application/data/demo_data.dart';
import 'package:mobile_application/models/board_image_item.dart';
import 'package:mobile_application/models/saved_input.dart';
import 'package:mobile_application/models/transcript_line_item.dart';
import 'package:mobile_application/widgets/ui_helpers.dart';

void main() {
  setUp(() {
    DemoData.savedInputs.clear();
    DemoData.notes.clear();
    DemoData.nextInputId = 1;
    DemoData.nextId = 1;
  });

  group('Scenario 1: Document Has Been Generated (Retention & Storage Management)', () {
    test('Discarding session inputs deletes raw inputs while preserving generated note', () {
      // Create session and generate notes
      final session = DemoData.addSessionInput(
        sessionId: 'sess_test_scenario_1',
        title: 'Neural Networks Lecture',
        audioTranscripts: ['[00:00] Intro to backpropagation', '[00:15] Gradient descent steps'],
        capturedImages: [
          CapturedImageItem(
            id: 1,
            title: 'Backprop Graph',
            ocrText: 'Backprop Loss function graph',
            capturedAt: DateTime.now(),
            capturedAtSecond: 10,
          ),
        ],
        audioDuration: '00:20',
      );

      final note = DemoData.generateNotesForInput(session);
      expect(note, isNotNull);
      expect(session.notesGenerated, isTrue);
      expect(DemoData.notes.first.title, contains('Neural Networks Lecture'));

      // User chooses to DISCARD inputs
      DemoData.applyRetentionDecision(
        session,
        discardInputs: true,
        note: note,
      );

      // Verify session inputs are purged from saved inputs
      expect(DemoData.savedInputs.any((s) => s.sessionId == 'sess_test_scenario_1'), isFalse);

      // CRITICAL: The generated document itself must NOT be affected
      expect(DemoData.notes.length, 1);
      expect(DemoData.notes.first.title, contains('Neural Networks Lecture'));
      expect(DemoData.notes.first.content, contains('Neural Networks Lecture'));
    });

    test('Keeping session inputs sets 7-day expiration', () {
      final session = DemoData.addSessionInput(
        sessionId: 'sess_test_keep_7_days',
        title: 'Computer Vision Architectures',
        audioTranscripts: ['[00:00] Convolution filters overview'],
        capturedImages: [],
        audioDuration: '00:10',
      );

      final note = DemoData.generateNotesForInput(session);
      expect(note, isNotNull);

      // User chooses to KEEP inputs
      DemoData.applyRetentionDecision(
        session,
        discardInputs: false,
        note: note,
      );

      // Inputs retained temporarily
      expect(DemoData.savedInputs.any((s) => s.sessionId == 'sess_test_keep_7_days'), isTrue);
      expect(session.expiresAt, isNotNull);

      // Expiry is approximately 7 days from now
      final diff = session.expiresAt!.difference(DateTime.now()).inDays;
      expect(diff >= 6 && diff <= 7, isTrue);
      expect(session.retentionLabel, contains('Auto-deletes in'));
    });

    test('Auto-deletion cleans expired completed sessions but NEVER unfinished sessions', () {
      // 1. Completed session with expired timestamp
      final expiredCompletedSession = SavedInput(
        id: 10,
        sessionId: 'sess_completed_expired',
        title: 'Completed Session Expired',
        type: 'Workshop Session',
        content: 'Old session',
        notesGenerated: true,
        expiresAt: DateTime.now().subtract(const Duration(days: 1)), // Expired yesterday
      );
      DemoData.savedInputs.add(expiredCompletedSession);

      // 2. Completed session not yet expired
      final activeCompletedSession = SavedInput(
        id: 11,
        sessionId: 'sess_completed_active',
        title: 'Completed Session Active',
        type: 'Workshop Session',
        content: 'Active session',
        notesGenerated: true,
        expiresAt: DateTime.now().add(const Duration(days: 5)),
      );
      DemoData.savedInputs.add(activeCompletedSession);

      // 3. Unfinished session (notes not generated) with an old date
      final unfinishedSession = SavedInput(
        id: 12,
        sessionId: 'sess_unfinished_saved',
        title: 'Unfinished Session',
        type: 'Workshop Session',
        content: 'Draft in progress',
        notesGenerated: false,
      );
      DemoData.savedInputs.add(unfinishedSession);

      // Run cleanup
      DemoData.cleanExpiredSessions();

      // Only the expired completed session should be removed
      expect(DemoData.savedInputs.any((s) => s.sessionId == 'sess_completed_expired'), isFalse);
      expect(DemoData.savedInputs.any((s) => s.sessionId == 'sess_completed_active'), isTrue);
      expect(DemoData.savedInputs.any((s) => s.sessionId == 'sess_unfinished_saved'), isTrue);
    });

    testWidgets('showPostNoteGenerationRetentionDialog shows recommendation and confirmation before discard', (WidgetTester tester) async {
      final session = DemoData.addSessionInput(
        sessionId: 'sess_dialog_test',
        title: 'Dialog Test Lecture',
        audioTranscripts: ['[00:00] Test audio text'],
        capturedImages: [],
        audioDuration: '00:05',
      );
      final note = DemoData.generateNotesForInput(session)!;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () {
                  showPostNoteGenerationRetentionDialog(
                    context: ctx,
                    session: session,
                    note: note,
                  );
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      // Tap open dialog
      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      // Verify Step 1: Dialog explaining storage limitation and recommended discard
      expect(find.text('Document Generated'), findsOneWidget);
      expect(find.textContaining('database storage is limited, deleting the session inputs is recommended'), findsOneWidget);
      expect(find.text('Keep Inputs (7 Days)'), findsOneWidget);
      expect(find.text('Discard Inputs (Recommended)'), findsOneWidget);

      // Tap Discard Inputs (Recommended)
      await tester.tap(find.text('Discard Inputs (Recommended)'));
      await tester.pumpAndSettle();

      // Verify Step 2: Confirmation dialog before deletion explaining note is preserved
      expect(find.text('Confirm Discard Inputs'), findsOneWidget);
      expect(find.textContaining('The generated document in Saved Notes will NOT be affected'), findsOneWidget);

      // Confirm discard
      await tester.tap(find.text('Confirm Discard'));
      await tester.pumpAndSettle();

      // Verify inputs discarded while note is intact
      expect(DemoData.savedInputs.any((s) => s.sessionId == 'sess_dialog_test'), isFalse);
      expect(DemoData.notes.any((n) => n.title.contains('Dialog Test Lecture')), isTrue);
    });
  });

  group('Scenario 2: Document Has NOT Been Generated (Save & Resume Sessions)', () {
    test('Enforces maximum 2 unfinished sessions quota', () {
      expect(DemoData.maxUnfinishedSessions, 2);
      expect(DemoData.unfinishedSessionCount, 0);
      expect(DemoData.canAddUnfinishedSession, isTrue);

      // Save 1st unfinished session
      DemoData.addSessionInput(
        sessionId: 'sess_draft_1',
        title: 'Draft Lecture 1',
        audioTranscripts: ['[00:00] First draft line'],
        capturedImages: [],
        audioDuration: '00:05',
      );
      expect(DemoData.unfinishedSessionCount, 1);
      expect(DemoData.canAddUnfinishedSession, isTrue);

      // Save 2nd unfinished session
      DemoData.addSessionInput(
        sessionId: 'sess_draft_2',
        title: 'Draft Lecture 2',
        audioTranscripts: ['[00:00] Second draft line'],
        capturedImages: [],
        audioDuration: '00:08',
      );
      expect(DemoData.unfinishedSessionCount, 2);

      // 3rd unfinished session must be blocked
      expect(DemoData.canAddUnfinishedSession, isFalse);
    });

    test('Reopening and editing an existing session updates in-place without exceeding quota', () {
      // Populate 2 unfinished sessions (quota full)
      DemoData.addSessionInput(
        sessionId: 'sess_draft_1',
        title: 'Draft Lecture 1',
        audioTranscripts: ['[00:00] Line 1'],
        capturedImages: [],
        audioDuration: '00:05',
      );
      DemoData.addSessionInput(
        sessionId: 'sess_draft_2',
        title: 'Draft Lecture 2',
        audioTranscripts: ['[00:00] Line 1'],
        capturedImages: [],
        audioDuration: '00:05',
      );
      expect(DemoData.canAddUnfinishedSession, isFalse);

      // Reopening and saving updates to 'sess_draft_1'
      final updated = DemoData.addSessionInput(
        sessionId: 'sess_draft_1',
        title: 'Draft Lecture 1 - Edited & Continued',
        audioTranscripts: ['[00:00] Line 1', '[00:15] Line 2 resumed in Studio'],
        capturedImages: [
          CapturedImageItem(
            id: 2,
            title: 'Resumed Board Capture',
            ocrText: 'Resumed content',
            capturedAt: DateTime.now(),
            capturedAtSecond: 12,
          ),
        ],
        audioDuration: '00:20',
      );

      // Must update existing session in-place, NOT create duplicate
      expect(DemoData.savedInputs.length, 2);
      expect(updated.title, 'Draft Lecture 1 - Edited & Continued');
      expect(updated.audioTranscripts.length, 2);
      expect(updated.capturedImages.length, 1);
      expect(updated.audioDuration, '00:20');
      expect(DemoData.unfinishedSessionCount, 2);
    });

    test('Generating notes for an unfinished session frees up a quota slot', () {
      final s1 = DemoData.addSessionInput(
        sessionId: 'sess_draft_1',
        title: 'Draft 1',
        audioTranscripts: ['[00:00] Text'],
        capturedImages: [],
        audioDuration: '00:05',
      );
      DemoData.addSessionInput(
        sessionId: 'sess_draft_2',
        title: 'Draft 2',
        audioTranscripts: ['[00:00] Text'],
        capturedImages: [],
        audioDuration: '00:05',
      );
      expect(DemoData.canAddUnfinishedSession, isFalse);

      // Generate notes for s1
      DemoData.generateNotesForInput(s1);
      expect(s1.notesGenerated, isTrue);

      // Unfinished session count drops to 1, freeing a slot!
      expect(DemoData.unfinishedSessionCount, 1);
      expect(DemoData.canAddUnfinishedSession, isTrue);
    });
  });

  group('Scenario 3: Audio and Image Consistency (Unified Session Grouping)', () {
    test('Audio and image inputs share the same session ID and are grouped together', () {
      const targetSessionId = 'sess_grouping_test_uuid';

      final session = DemoData.addSessionInput(
        sessionId: targetSessionId,
        title: 'Physics Mechanics Session',
        audioTranscripts: [
          '[00:00] Welcome to kinematics',
          '[00:10] Newton second law of motion',
        ],
        allTranscriptLines: [
          TranscriptLineItem(
            id: 'chunk_1',
            timestamp: '00:00',
            text: 'Welcome to kinematics',
            secondTrigger: 0,
          ),
          TranscriptLineItem(
            id: 'chunk_2',
            timestamp: '00:10',
            text: 'Newton second law of motion',
            secondTrigger: 10,
          ),
        ],
        capturedImages: [
          CapturedImageItem(
            id: 3,
            title: 'Free Body Diagram',
            ocrText: 'Diagram of forces',
            capturedAt: DateTime.now(),
            capturedAtSecond: 5,
          ),
          CapturedImageItem(
            id: 4,
            title: 'Formula Derivation',
            ocrText: 'F = m * a derivation',
            capturedAt: DateTime.now(),
            capturedAtSecond: 15,
          ),
        ],
        audioDuration: '00:20',
      );

      // All inputs exist under the same session ID
      expect(session.sessionId, targetSessionId);
      expect(session.transcriptLines.length, 2);
      expect(session.capturedImages.length, 2);

      // Images and audio entries have matching relative timestamps
      expect(session.transcriptLines[0].secondTrigger, 0);
      expect(session.capturedImages[0].capturedAtSecond, 5);
      expect(session.transcriptLines[1].secondTrigger, 10);
      expect(session.capturedImages[1].capturedAtSecond, 15);
    });
  });
}
