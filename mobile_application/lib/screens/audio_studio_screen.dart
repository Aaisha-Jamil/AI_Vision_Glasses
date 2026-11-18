
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/demo_data.dart';
import '../models/board_image_item.dart';
import '../models/saved_input.dart';
import '../models/transcript_line_item.dart';
import '../services/audio_service.dart';
import '../widgets/board_preview_widget.dart';
import '../widgets/ui_helpers.dart';
import 'board_camera_screen.dart';
import 'saved_inputs_screen.dart';
import '../theme/app_theme.dart';

class LectureTranscriptEntry {
  LectureTranscriptEntry({
    required this.id,
    required this.timestamp,
    required this.text,
    required this.secondTrigger,
    this.isFlagged = false,
    this.flagReason = 'Ambient Noise / Side Speech',
  });

  final String id;
  final String timestamp;
  String text;
  final int secondTrigger;
  bool isFlagged;
  final String flagReason;

  String get formatted =>
      isFlagged ? '[$timestamp] [FLAGGED NOISE] $text' : '[$timestamp] $text';
}

class AudioStudioScreen extends StatefulWidget {
  const AudioStudioScreen({super.key, this.resumedSession});

  final SavedInput? resumedSession;

  @override
  State<AudioStudioScreen> createState() => _AudioStudioScreenState();
}

class _AudioStudioScreenState extends State<AudioStudioScreen> {
  Color get primaryCol => AppTheme.primary(context);

  Timer? timer;

  int seconds = 0;
  bool isRecording = false;
  bool isPaused = false;
  bool isAudioActionInProgress = false;

  late List<LectureTranscriptEntry> sessionTranscriptEntries;

  final List<CapturedImageItem> sessionCapturedImages = [];

  StreamSubscription? _liveTranscriptSub;

  bool isLiveBackend = false;

  String? currentSessionId;

  @override
  void initState() {
    super.initState();

    if (widget.resumedSession != null) {
      _loadResumedSession(widget.resumedSession!);
    } else {
      currentSessionId = 'sess_${DateTime.now().millisecondsSinceEpoch}';
      _resetTranscriptEntries();
    }

    _initLiveTranscriptListener();
  }

  void _loadResumedSession(SavedInput s) {
    currentSessionId = s.sessionId;

    if (s.audioDuration != null && s.audioDuration!.contains(':')) {
      final parts = s.audioDuration!.split(':');
      final m = int.tryParse(parts[0]) ?? 0;
      final sec = int.tryParse(parts[1]) ?? 0;

      seconds = m * 60 + sec;
    }

    sessionTranscriptEntries = s.transcriptLines.map((l) {
      return LectureTranscriptEntry(
        id: l.id,
        timestamp: l.timestamp,
        text: l.text,
        secondTrigger: l.secondTrigger,
        isFlagged: l.isFlagged,
        flagReason: l.flagReason,
      );
    }).toList();

    sessionCapturedImages.clear();
    sessionCapturedImages.addAll(s.capturedImages);
  }

  void _initLiveTranscriptListener() {
    _liveTranscriptSub = AudioService().liveTranscriptStream.listen((data) {
      if (!mounted) return;

      final type = data['type'] as String?;

      if (type == 'chunk_created' ||
          data.containsKey('transcript') ||
          data.containsKey('transcript_text')) {
        final text = (data['transcript'] ?? data['transcript_text'] ?? '')
            .toString()
            .trim();

        if (text.isEmpty) return;

        final chunkId =
            (data['chunk_id'] ??
                    data['id'] ??
                    'chunk_${DateTime.now().millisecondsSinceEpoch}')
                .toString();

        final isNoise =
            data['is_noise'] == true || data['is_flagged_noise'] == true;

        final reason =
            (data['reason'] ?? data['noise_reason'] ?? 'Flagged Noise')
                .toString();

        setState(() {
          isLiveBackend = true;

          final existingIdx = sessionTranscriptEntries.indexWhere(
            (e) => e.id == chunkId,
          );

          if (existingIdx >= 0) {
            sessionTranscriptEntries[existingIdx].text = text;
            sessionTranscriptEntries[existingIdx].isFlagged = isNoise;
          } else {
            sessionTranscriptEntries.add(
              LectureTranscriptEntry(
                id: chunkId,
                timestamp: timeText,
                text: text,
                secondTrigger: seconds,
                isFlagged: isNoise,
                flagReason: reason,
              ),
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _liveTranscriptSub?.cancel();
    timer?.cancel();
    super.dispose();
  }

  void _resetTranscriptEntries() {
    sessionTranscriptEntries = [];
  }

  String get timeText {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');

    return '$minutes:$secs';
  }

  List<LectureTranscriptEntry> get displayedTranscriptEntries {
    if (isRecording) {
      return sessionTranscriptEntries.where((e) => !e.isFlagged).toList();
    }

    return sessionTranscriptEntries;
  }

  List<String> get activeTranscripts {
    return displayedTranscriptEntries.map((e) => e.formatted).toList();
  }

  List<TranscriptLineItem> get allTranscriptLineItems {
    return displayedTranscriptEntries
        .map(
          (e) => TranscriptLineItem(
            id: e.id,
            timestamp: e.timestamp,
            text: e.text,
            isFlagged: e.isFlagged,
            flagReason: e.flagReason,
            secondTrigger: e.secondTrigger,
          ),
        )
        .toList();
  }

  // Start local microphone recording and backend session.
  Future<void> startRecording() async {
    if (isAudioActionInProgress) return;

    timer?.cancel();

    setState(() {
      isAudioActionInProgress = true;
      seconds = 0;
      isRecording = false;
      isPaused = false;
      isLiveBackend = false;
      sessionTranscriptEntries.clear();
    });

    try {
      final response = await AudioService().startSession(
        title: 'Lecture Workshop Session #${DemoData.nextInputId}',
        source: 'browser',
      );

      final sessionId = response['session_id']?.toString();

      if (sessionId == null || sessionId.isEmpty) {
        throw Exception('Backend did not return a session ID.');
      }

      if (!mounted) return;

      setState(() {
        isRecording = true;
        isPaused = false;
        currentSessionId = sessionId;
        isAudioActionInProgress = false;
      });

      _startTimer();
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isRecording = false;
        isPaused = false;
        isAudioActionInProgress = false;
      });

      showMessage(context, 'Recording could not start: $error');
    }
  }

  // Timer runs only while microphone is actively recording.
  void _startTimer() {
    timer?.cancel();

    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !isRecording || isPaused) return;

      setState(() {
        seconds++;
      });
    });
  }

  // Actual microphone Pause/Resume.
  Future<void> togglePause() async {
    if (!isRecording || isAudioActionInProgress) return;

    setState(() {
      isAudioActionInProgress = true;
    });

    try {
      if (!isPaused) {
        await AudioService().pauseRecording();

        timer?.cancel();

        if (!mounted) return;

        setState(() {
          isPaused = true;
          isAudioActionInProgress = false;
        });

        showMessage(context, 'Recording paused.');
      } else {
        await AudioService().resumeRecording();

        if (!mounted) return;

        setState(() {
          isPaused = false;
          isAudioActionInProgress = false;
        });

        _startTimer();

        showMessage(context, 'Recording resumed.');
      }
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isAudioActionInProgress = false;
      });

      showMessage(context, 'Microphone Pause/Resume failed: $error');
    }
  }

  Future<void> stopRecording() async {
    if (!isRecording || isAudioActionInProgress) return;

    timer?.cancel();

    setState(() {
      isAudioActionInProgress = true;
    });

    try {
      await AudioService().stopSession();

      if (!mounted) return;

      setState(() {
        isRecording = false;
        isPaused = false;
        isAudioActionInProgress = false;
      });

      showMessage(
        context,
        'Lecture recording completed. Flagged noise lines are now highlighted in red below with Keep, Delete, and Edit options.',
      );
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isRecording = false;
        isPaused = false;
        isAudioActionInProgress = false;
      });

      showMessage(context, 'Could not stop backend session: $error');
    }
  }

  void keepFlaggedLine(LectureTranscriptEntry entry) {
    setState(() {
      entry.isFlagged = false;
    });

    if (!entry.id.startsWith('line_')) {
      AudioService().overrideChunk(entry.id, 'KEPT');
    }

    showMessage(context, 'Line kept in transcripts.');
  }

  void deleteTranscriptLine(LectureTranscriptEntry entry) {
    setState(() {
      sessionTranscriptEntries.removeWhere((e) => e.id == entry.id);
    });

    if (!entry.id.startsWith('line_')) {
      AudioService().overrideChunk(entry.id, 'DELETED');
    }

    showMessage(context, 'Transcript line deleted.');
  }

  Future<void> editTranscriptLine(LectureTranscriptEntry entry) async {
    final controller = TextEditingController(text: entry.text);

    bool unflagOnSave = entry.isFlagged;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Icon(
                entry.isFlagged ? Icons.warning_amber_rounded : Icons.edit_note,
                color: entry.isFlagged ? AppTheme.danger : primaryCol,
              ),
              const SizedBox(width: 8),
              Text(
                entry.isFlagged
                    ? 'Edit Flagged Noise / Line'
                    : 'Edit Transcript Line',
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: primaryCol.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Timestamp: [${entry.timestamp}]',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  maxLines: 4,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Transcript Text',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (entry.isFlagged) ...[
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Mark as clean speech (remove red flag)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    value: unflagOnSave,
                    onChanged: (val) {
                      setDialogState(() {
                        unflagOnSave = val ?? true;
                      });
                    },
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.check),
              label: const Text('Save Changes'),
            ),
          ],
        ),
      ),
    );

    if (saved == true && mounted) {
      setState(() {
        entry.text = controller.text.trim();

        if (entry.isFlagged && unflagOnSave) {
          entry.isFlagged = false;
        }
      });

      showMessage(context, 'Transcript line updated.');
    }

    controller.dispose();
  }

  Future<void> openCameraToCaptureImage() async {
    currentSessionId ??= 'sess_${DateTime.now().millisecondsSinceEpoch}';

    final capturedItem = await Navigator.push<CapturedImageItem>(
      context,
      MaterialPageRoute(
        builder: (_) => BoardCameraScreen(
          isSessionMode: true,
          sessionId: currentSessionId,
          sessionTitle: 'Workshop Lecture ($timeText)',
        ),
      ),
    );

    if (capturedItem != null && mounted) {
      final itemWithTime = CapturedImageItem(
        id: capturedItem.id,
        title: capturedItem.title,
        ocrText: capturedItem.ocrText,
        option: capturedItem.option,
        diagramType: capturedItem.diagramType,
        capturedAtSecond: seconds,
        capturedAt: capturedItem.capturedAt,
        localImagePath: capturedItem.localImagePath,
        remoteImageUrl: capturedItem.remoteImageUrl,
        snapshotId: capturedItem.snapshotId,
        confidenceScore: capturedItem.confidenceScore,
        peopleDetected: capturedItem.peopleDetected,
      );

      setState(() {
        sessionCapturedImages.add(itemWithTime);
      });

      showMessage(
        context,
        'Board capture "${itemWithTime.title}" added to workshop session (${itemWithTime.option.label}).',
      );
    }
  }

  void addSampleImageQuickly() {
    final count = sessionCapturedImages.length + 1;

    final item = CapturedImageItem(
      id: DateTime.now().millisecondsSinceEpoch,
      title: 'Board Capture #$count (Formulae & Architectures)',
      ocrText:
          '• Formula: Loss = λ · ||I_blur - I_orig||\n'
          '• Quantization: FP16 TensorRT\n'
          '• Local Privacy Vault: Active\n'
          '• Frame Latency: 38ms',
      option: BoardImageOption.both,
      capturedAtSecond: seconds,
    );

    setState(() {
      sessionCapturedImages.add(item);
    });

    showMessage(context, 'Sample board image attached to workshop session.');
  }

  Future<void> saveSessionToSavedInputs() async {
    final navigator = Navigator.of(context);

    final isExistingSession =
        currentSessionId != null &&
        DemoData.savedInputs.any((s) => s.sessionId == currentSessionId);

    if (!isExistingSession && !DemoData.canAddUnfinishedSession) {
      await showStorageQuotaExceededDialog(context);
      return;
    }

    if (isRecording) {
      final shouldStop = await askConfirmation(
        context,
        title: 'Stop Recording First?',
        message:
            'The lecture is still recording. Stop recording and save session materials?',
        confirmText: 'Stop & Save',
      );

      if (!mounted || !shouldStop) return;

      await stopRecording();

      if (!mounted) return;
    }

    final defaultSessionName =
        'Workshop Lecture ${DateTime.now().month}/${DateTime.now().day} - #${DemoData.nextInputId}';

    final nameController = TextEditingController(text: defaultSessionName);

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.bookmark_add, color: primaryCol),
            const SizedBox(width: 8),
            const Text('Name Workshop Session'),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter a name to save this session\'s audio transcripts and captured images in Saved Inputs:',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Session Name',
                  hintText: 'e.g. AI Vision Architecture Lecture',
                  prefixIcon: Icon(Icons.edit_note),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(dialogContext)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '• Audio Duration: $timeText',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '• Audio Transcripts: ${displayedTranscriptEntries.length} lines (incl. flagged noise)',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '• Board Captures: ${sessionCapturedImages.length} images attached',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.save),
            label: const Text('Save Session'),
          ),
        ],
      ),
    );

    if (!mounted || shouldSave != true) {
      nameController.dispose();
      return;
    }

    final sessionName = nameController.text.trim().isEmpty
        ? defaultSessionName
        : nameController.text.trim();

    nameController.dispose();

    DemoData.addSessionInput(
      sessionId: currentSessionId,
      title: sessionName,
      audioTranscripts: activeTranscripts,
      capturedImages: sessionCapturedImages,
      audioDuration: timeText,
      allTranscriptLines: allTranscriptLineItems,
    );

    if (!mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);

    messenger?.hideCurrentSnackBar();

    messenger?.showSnackBar(
      SnackBar(
        content: Text('Session "$sessionName" saved in Saved Inputs.'),
        action: SnackBarAction(
          label: 'View Inputs',
          onPressed: () {
            if (navigator.mounted) {
              navigator.push(
                MaterialPageRoute(
                  builder: (_) => const SavedInputsScreen(),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  Future<void> generateNotes() async {
    if (isRecording) {
      showMessage(context, 'Stop the recording first.');
      return;
    }

    final satisfaction = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Generate Notes'),
        content: const Text('Was this lecture recording session satisfactory?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );

    if (!mounted || satisfaction == null) return;

    if (!satisfaction) {
      showMessage(context, 'You can record another session.');
      return;
    }

    final shouldSave = await askConfirmation(
      context,
      title: 'Save Lecture Notes?',
      message:
          'Generate and save notes for this lecture session to Saved Notes?',
      confirmText: 'Generate Notes',
    );

    if (!mounted || !shouldSave) return;

    final session = DemoData.addSessionInput(
      sessionId: currentSessionId,
      title: 'Workshop Lecture Session #${DemoData.nextInputId}',
      audioTranscripts: activeTranscripts,
      capturedImages: sessionCapturedImages,
      audioDuration: timeText,
      allTranscriptLines: allTranscriptLineItems,
    );

    final note = await DemoData.generateAiNotesForInput(session);

    if (note != null && mounted) {
      await showPostNoteGenerationRetentionDialog(
        context: context,
        session: session,
        note: note,
        onDone: () {
          if (mounted) setState(() {});
        },
      );
    }
  }

  // Builds a transcript line.
  Widget _buildTranscriptEntryWidget(
    LectureTranscriptEntry entry,
    bool isDark,
    ThemeData theme,
  ) {
    if (entry.isFlagged) {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark
              ? AppTheme.dangerSurfaceDark
              : AppTheme.dangerSurfaceLight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDark ? AppTheme.dangerDark : AppTheme.dangerSoft,
            width: 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '[${entry.timestamp}]',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isDark
                          ? AppTheme.dangerLight
                          : AppTheme.dangerDeep,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.danger,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 12,
                        color: Colors.white,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'FLAGGED NOISE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  entry.flagReason,
                  style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: isDark ? AppTheme.dangerLight : AppTheme.dangerDark,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              entry.text,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white : AppTheme.ink,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: () => keepFlaggedLine(entry),
                  icon: Icon(Icons.check, size: 14, color: primaryCol),
                  label: Text(
                    'Keep',
                    style: TextStyle(color: primaryCol, fontSize: 12),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: primaryCol),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    minimumSize: const Size(0, 32),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => editTranscriptLine(entry),
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 14,
                    color: AppTheme.info,
                  ),
                  label: const Text(
                    'Edit',
                    style: TextStyle(color: AppTheme.info, fontSize: 12),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.info),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    minimumSize: const Size(0, 32),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => deleteTranscriptLine(entry),
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Colors.white,
                  ),
                  label: const Text(
                    'Delete',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.danger,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    minimumSize: const Size(0, 32),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.03) : AppTheme.paleSea,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '[${entry.timestamp}]',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.text,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
          if (!isRecording && seconds > 0)
            IconButton(
              icon: const Icon(
                Icons.edit_outlined,
                size: 16,
                color: AppTheme.mutedText,
              ),
              tooltip: 'Edit line',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => editTranscriptLine(entry),
            ),
        ],
      ),
    );
  }

  // Builds a captured image card inline in the transcript.
  Widget _buildStudioInlineImage(
    CapturedImageItem img,
    bool isDark,
    ThemeData theme,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: primaryCol.withValues(alpha: 0.45),
          width: 1.5,
        ),
        color: isDark
            ? primaryCol.withValues(alpha: 0.06)
            : primaryCol.withValues(alpha: 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: primaryCol.withValues(alpha: 0.12),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(10),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.camera_alt_outlined, size: 15, color: primaryCol),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    img.title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: primaryCol,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: primaryCol.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    img.option.label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: primaryCol,
                    ),
                  ),
                ),
                if (img.capturedAtSecond != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '@ ${(img.capturedAtSecond! ~/ 60).toString().padLeft(2, '0')}:${(img.capturedAtSecond! % 60).toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white60 : Colors.black45,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: BoardPreviewWidget(item: img, compact: true),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final entries = displayedTranscriptEntries;
    final hasFlaggedLines = entries.any((e) => e.isFlagged);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi-Input Notes Studio'),
        actions: [
          IconButton(
            tooltip: 'Server Connection Settings',
            icon: const Icon(Icons.router_outlined),
            onPressed: () => showServerConfigDialog(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          pageHeading(
            'Workshop Lecture Studio',
            'Record lecture audio transcripts & capture board images',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                children: [
                  Icon(
                    isRecording ? Icons.graphic_eq : Icons.mic_none,
                    size: 64,
                    color: isRecording ? AppTheme.danger : primaryCol,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    timeText,
                    style: const TextStyle(
                      fontSize: 42,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Chip(
                    avatar: Icon(
                      isRecording
                          ? (isPaused ? Icons.pause : Icons.circle)
                          : Icons.stop_circle_outlined,
                      size: 16,
                      color: isRecording ? AppTheme.danger : AppTheme.mutedText,
                    ),
                    label: Text(
                      !isRecording
                          ? 'READY'
                          : isPaused
                              ? 'PAUSED'
                              : 'RECORDING LIVE',
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Recording audio transcripts and synchronized lecture board captures.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: isRecording || isAudioActionInProgress
                            ? null
                            : startRecording,
                        icon: const Icon(Icons.fiber_manual_record),
                        label: const Text('Start'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.dangerDark,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: isRecording && !isAudioActionInProgress
                            ? togglePause
                            : null,
                        icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
                        label: Text(isPaused ? 'Resume' : 'Pause'),
                      ),
                      OutlinedButton.icon(
                        onPressed: isRecording && !isAudioActionInProgress
                            ? stopRecording
                            : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                    ],
                  ),
                  if (isAudioActionInProgress) ...[
                    const SizedBox(height: 12),
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Transcript section.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.subject, color: primaryCol),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Lecture Audio Transcripts',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (isRecording)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.danger.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.circle,
                                color: AppTheme.danger,
                                size: 8,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'LIVE',
                                style: TextStyle(
                                  color: AppTheme.danger,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (seconds > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: primaryCol.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'COMPLETED',
                            style: TextStyle(
                              color: primaryCol,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (!isRecording && seconds > 0 && hasFlaggedLines) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.danger.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: AppTheme.danger.withValues(alpha: 0.2),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: AppTheme.danger,
                            size: 16,
                          ),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Flagged noise lines are highlighted in red shade below. Use Keep, Edit, or Delete to manage.',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.danger,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              isRecording ? Icons.mic : Icons.mic_none,
                              size: 40,
                              color: isRecording ? AppTheme.danger : primaryCol,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              isRecording
                                  ? isPaused
                                      ? 'Recording paused.\nPress Resume to continue.'
                                      : 'Listening for live speech in real-time...\nSpeak into your microphone.'
                                  : 'No audio transcripts recorded yet.\nTap Start to begin live audio recording.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: isDark
                                    ? AppTheme.mutedTextLight
                                    : AppTheme.mutedText,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else ...[
                    ...() {
                      final List<Widget> transcriptWidgets = [];

                      if (!isRecording &&
                          seconds > 0 &&
                          sessionCapturedImages.isNotEmpty) {
                        final Map<int, List<CapturedImageItem>> imgByIdx = {};

                        for (final img in sessionCapturedImages) {
                          int targetIdx = -1;

                          for (int k = 0; k < entries.length; k++) {
                            if (img.capturedAtSecond != null &&
                                entries[k].secondTrigger <=
                                    img.capturedAtSecond!) {
                              targetIdx = k;
                            }
                          }

                          imgByIdx.putIfAbsent(targetIdx, () => []).add(img);
                        }

                        final preImgs = imgByIdx[-1];

                        if (preImgs != null) {
                          for (final img in preImgs) {
                            transcriptWidgets.add(
                              _buildStudioInlineImage(img, isDark, theme),
                            );
                          }
                        }

                        for (int idx = 0; idx < entries.length; idx++) {
                          final entry = entries[idx];

                          transcriptWidgets.add(
                            _buildTranscriptEntryWidget(entry, isDark, theme),
                          );

                          final imgsHere = imgByIdx[idx];

                          if (imgsHere != null) {
                            for (final img in imgsHere) {
                              transcriptWidgets.add(
                                _buildStudioInlineImage(img, isDark, theme),
                              );
                            }
                          }
                        }
                      } else {
                        for (final entry in entries) {
                          transcriptWidgets.add(
                            _buildTranscriptEntryWidget(entry, isDark, theme),
                          );
                        }
                      }

                      return transcriptWidgets;
                    }(),
                  ],
                  if (isRecording && !isPaused) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: primaryCol,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Transcribing live speech line by line...',
                          style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: AppTheme.mutedText,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Captured images section.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.photo_library_outlined, color: primaryCol),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Captured Board Images (${sessionCapturedImages.length})',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Capture Board Photo',
                        icon: const Icon(Icons.add_a_photo_outlined),
                        onPressed: openCameraToCaptureImage,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (sessionCapturedImages.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: AppTheme.mutedText,
                            size: 20,
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'No board images captured yet in this lecture session. Use "Capture Board Image" below.',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.mutedText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (!isRecording && seconds > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: primaryCol.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: primaryCol.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            color: primaryCol,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${sessionCapturedImages.length} board capture${sessionCapturedImages.length == 1 ? '' : 's'} displayed inline within the transcript above at their exact capture positions.',
                              style: TextStyle(fontSize: 12, color: primaryCol),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...sessionCapturedImages.asMap().entries.map((entry) {
                      final index = entry.key;
                      final img = entry.value;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    img.title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                Chip(
                                  label: Text(
                                    img.option.label,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  padding: EdgeInsets.zero,
                                  backgroundColor: primaryCol.withValues(
                                    alpha: 0.15,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    size: 18,
                                    color: AppTheme.danger,
                                  ),
                                  tooltip: 'Remove from session',
                                  onPressed: () {
                                    setState(() {
                                      sessionCapturedImages.removeAt(index);
                                    });
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            BoardPreviewWidget(item: img, compact: true),
                          ],
                        ),
                      );
                    }),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: openCameraToCaptureImage,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text(
                        'Capture Board Image (With Side Transcripts & 3 Options)',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Session actions.
          Card(
            color: Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.05),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: 0.3),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Session Actions',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'If you do not want to generate notes now, save the whole session material (transcripts + images) directly to Saved Inputs:',
                    style: TextStyle(fontSize: 12, color: AppTheme.mutedText),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: saveSessionToSavedInputs,
                      icon: const Icon(Icons.bookmark_add),
                      label: const Text('Save Session to Saved Inputs'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryCol,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: generateNotes,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Generate Notes Now'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
