import 'dart:async';
import 'package:flutter/material.dart';
import '../data/demo_data.dart';
import '../models/board_image_item.dart';
import '../models/transcript_line_item.dart';
import '../widgets/board_preview_widget.dart';
import '../widgets/ui_helpers.dart';
import 'board_camera_screen.dart';
import 'saved_inputs_screen.dart';

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

  String get formatted => isFlagged ? '[$timestamp] [FLAGGED NOISE] $text' : '[$timestamp] $text';
}

class AudioStudioScreen extends StatefulWidget {
  const AudioStudioScreen({super.key});

  @override
  State<AudioStudioScreen> createState() => _AudioStudioScreenState();
}

class _AudioStudioScreenState extends State<AudioStudioScreen> {
  Timer? timer;
  int seconds = 0;
  bool isRecording = false;
  bool isPaused = false;

  late List<LectureTranscriptEntry> sessionTranscriptEntries;
  final List<CapturedImageItem> sessionCapturedImages = [];

  @override
  void initState() {
    super.initState();
    _resetTranscriptEntries();
  }

  void _resetTranscriptEntries() {
    sessionTranscriptEntries = [
      LectureTranscriptEntry(
        id: 'line_1',
        timestamp: '00:04',
        text: 'Today we will discuss the main workshop topics on AI Vision Glasses.',
        secondTrigger: 2,
        isFlagged: false,
      ),
      LectureTranscriptEntry(
        id: 'line_2',
        timestamp: '00:11',
        text: 'What should I eat for lunch today? Maybe pizza.',
        secondTrigger: 6,
        isFlagged: true,
        flagReason: 'Off-topic Side Conversation',
      ),
      LectureTranscriptEntry(
        id: 'line_3',
        timestamp: '00:16',
        text: 'First, identify the important concepts: edge processing and low-latency inference.',
        secondTrigger: 10,
        isFlagged: false,
      ),
      LectureTranscriptEntry(
        id: 'line_4',
        timestamp: '00:27',
        text: '[Loud hallway door slam and background crowd chatter]',
        secondTrigger: 16,
        isFlagged: true,
        flagReason: 'Ambient Noise Spike',
      ),
      LectureTranscriptEntry(
        id: 'line_5',
        timestamp: '00:32',
        text: 'Next, organize the key concepts and equations captured from the lecture board.',
        secondTrigger: 22,
        isFlagged: false,
      ),
      LectureTranscriptEntry(
        id: 'line_6',
        timestamp: '00:48',
        text: 'Finally, review the privacy-preserving pipeline with YOLOv8 face blurring.',
        secondTrigger: 30,
        isFlagged: false,
      ),
    ];
  }

  String get timeText {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$secs';
  }

  /// Determines which lines are displayed based on recording state:
  /// - During recording: ONLY unflagged lines are shown with timestamps.
  /// - Stopped/Completed: BOTH flagged and unflagged lines are shown,
  ///   with flagged lines highlighted in red shade.
  /// - Initial idle: unflagged lines preview.
  List<LectureTranscriptEntry> get displayedTranscriptEntries {
    if (isRecording) {
      // During recording: show only unflagged lines
      return sessionTranscriptEntries
          .where((e) => !e.isFlagged && seconds >= e.secondTrigger)
          .toList();
    }
    if (seconds == 0) {
      // Idle preview before recording starts: unflagged lines only
      return sessionTranscriptEntries.where((e) => !e.isFlagged).toList();
    }
    // Completed/Stopped: show BOTH unflagged and flagged lines up to current time
    final recorded = sessionTranscriptEntries
        .where((e) => seconds >= e.secondTrigger || seconds >= 30)
        .toList();
    return recorded.isNotEmpty ? recorded : sessionTranscriptEntries;
  }

  /// All formatted transcript strings (flagged + unflagged) for the current
  /// displayed set. Used when saving a session so nothing is silently dropped.
  List<String> get activeTranscripts {
    return displayedTranscriptEntries.map((e) => e.formatted).toList();
  }

  /// All structured transcript entries (flagged + unflagged) for the current
  /// displayed set, converted to TranscriptLineItem for persistence.
  List<TranscriptLineItem> get allTranscriptLineItems {
    return displayedTranscriptEntries
        .map((e) => TranscriptLineItem(
              id: e.id,
              timestamp: e.timestamp,
              text: e.text,
              isFlagged: e.isFlagged,
              flagReason: e.flagReason,
              secondTrigger: e.secondTrigger,
            ))
        .toList();
  }

  void startRecording() {
    timer?.cancel();
    setState(() {
      seconds = 0;
      isRecording = true;
      isPaused = false;
      _resetTranscriptEntries();
    });
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || isPaused) return;
      setState(() => seconds++);
    });
  }

  void togglePause() {
    if (!isRecording) return;
    setState(() => isPaused = !isPaused);
  }

  void stopRecording() {
    timer?.cancel();
    setState(() {
      isRecording = false;
      isPaused = false;
    });
    showMessage(
      context,
      'Lecture recording completed. Flagged noise lines are now highlighted in red below with Keep, Delete, and Edit options.',
    );
  }

  void keepFlaggedLine(LectureTranscriptEntry entry) {
    setState(() {
      entry.isFlagged = false;
    });
    showMessage(context, 'Line kept in transcripts.');
  }

  void deleteTranscriptLine(LectureTranscriptEntry entry) {
    setState(() {
      sessionTranscriptEntries.removeWhere((e) => e.id == entry.id);
    });
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
                color: entry.isFlagged ? Colors.red : Colors.teal,
              ),
              const SizedBox(width: 8),
              Text(entry.isFlagged ? 'Edit Flagged Noise / Line' : 'Edit Transcript Line'),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.12),
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
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    value: unflagOnSave,
                    onChanged: (val) {
                      setDialogState(() => unflagOnSave = val ?? true);
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
    final capturedItem = await Navigator.push<CapturedImageItem>(
      context,
      MaterialPageRoute(
        builder: (_) => BoardCameraScreen(
          isSessionMode: true,
          sessionTitle: 'Workshop Lecture ($timeText)',
        ),
      ),
    );

    if (capturedItem != null && mounted) {
      setState(() {
        sessionCapturedImages.add(capturedItem);
      });
      showMessage(
        context,
        'Board capture "${capturedItem.title}" added to workshop session (${capturedItem.option.label}).',
      );
    }
  }

  void addSampleImageQuickly() {
    final count = sessionCapturedImages.length + 1;
    final item = CapturedImageItem(
      id: DateTime.now().millisecondsSinceEpoch,
      title: 'Board Capture #$count (Formulae & Architectures)',
      ocrText: '• Formula: Loss = λ · ||I_blur - I_orig||\n'
          '• Quantization: FP16 TensorRT\n'
          '• Local Privacy Vault: Active\n'
          '• Frame Latency: 38ms',
      option: BoardImageOption.both,
    );
    setState(() {
      sessionCapturedImages.add(item);
    });
    showMessage(context, 'Sample board image attached to workshop session.');
  }

  Future<void> saveSessionToSavedInputs() async {
    if (isRecording) {
      final shouldStop = await askConfirmation(
        context,
        title: 'Stop Recording First?',
        message: 'The lecture is still recording. Stop recording and save session materials?',
        confirmText: 'Stop & Save',
      );
      if (!mounted || !shouldStop) return;
      stopRecording();
    }

    final defaultSessionName =
        'Workshop Lecture ${DateTime.now().month}/${DateTime.now().day} - #${DemoData.nextInputId}';
    final nameController = TextEditingController(text: defaultSessionName);

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bookmark_add, color: Colors.teal),
            SizedBox(width: 8),
            Text('Name Workshop Session'),
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
                  color: Theme.of(dialogContext).colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '• Audio Duration: $timeText',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '• Audio Transcripts: ${displayedTranscriptEntries.length} lines (incl. flagged noise)',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '• Board Captures: ${sessionCapturedImages.length} images attached',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
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
      title: sessionName,
      audioTranscripts: activeTranscripts,
      capturedImages: sessionCapturedImages,
      audioDuration: timeText,
      allTranscriptLines: allTranscriptLineItems,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Session "$sessionName" saved in Saved Inputs.'),
          action: SnackBarAction(
            label: 'View Inputs',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SavedInputsScreen()),
              );
            },
          ),
        ),
      );
    }
  }

  Future<void> generateNotes() async {
    if (isRecording) {
      showMessage(context, 'Stop the demo recording first.');
      return;
    }

    final satisfaction = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Generate Notes'),
        content: const Text(
          'Was this demo recording session satisfactory?',
        ),
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
      showMessage(context, 'You can record another demo session.');
      return;
    }

    final shouldSave = await askConfirmation(
      context,
      title: 'Save Demo Notes?',
      message: 'Generate and save notes for this lecture session to Saved Notes?',
      confirmText: 'Generate Notes',
    );

    if (!mounted || !shouldSave) return;

    final session = DemoData.addSessionInput(
      title: 'Workshop Lecture Session #${DemoData.nextInputId}',
      audioTranscripts: activeTranscripts,
      capturedImages: sessionCapturedImages,
      audioDuration: timeText,
      allTranscriptLines: allTranscriptLineItems,
    );

    DemoData.generateNotesForInput(session);
    showMessage(context, 'Comprehensive demo notes generated and saved.');
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final entries = displayedTranscriptEntries;
    final hasFlaggedLines = entries.any((e) => e.isFlagged);

    return Scaffold(
      appBar: AppBar(title: const Text('Multi-Input Notes Studio')),
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
                    color: isRecording ? Colors.red : Colors.teal,
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
                      color: isRecording ? Colors.red : Colors.grey,
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
                        onPressed: isRecording ? null : startRecording,
                        icon: const Icon(Icons.fiber_manual_record),
                        label: const Text('Start'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: isRecording ? togglePause : null,
                        icon: Icon(
                          isPaused ? Icons.play_arrow : Icons.pause,
                        ),
                        label: Text(isPaused ? 'Resume' : 'Pause'),
                      ),
                      OutlinedButton.icon(
                        onPressed: isRecording ? stopRecording : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Audio Speech Transcripts:
          // - During recording: Only clean transcription line by line with timestamps. Flagged noise hidden.
          // - After recording stopped/completed: Shows both flagged and unflagged noise lines.
          //   Flagged noise lines are highlighted in red shade with Keep, Delete, Edit options!
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.subject, color: Colors.teal),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Lecture Audio Transcripts',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (isRecording)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.circle, color: Colors.red, size: 8),
                              SizedBox(width: 6),
                              Text(
                                'LIVE',
                                style: TextStyle(
                                  color: Colors.red,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (seconds > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.teal.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'COMPLETED',
                            style: TextStyle(
                              color: Colors.teal,
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
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.red, size: 16),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Flagged noise lines are highlighted in red shade below. Use Keep, Edit, or Delete to manage.',
                              style: TextStyle(fontSize: 11, color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  // Line by line transcript display
                  if (entries.isEmpty && isRecording)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: Text(
                          'Listening and transcribing speech...',
                          style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
                        ),
                      ),
                    )
                  else
                    ...entries.map((entry) {
                      if (entry.isFlagged) {
                        // Flagged noise line: Highlighted within red shade with Keep, Edit, Delete options
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF381A20) : const Color(0xFFFFEBEE),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isDark ? Colors.red.shade700 : Colors.red.shade300,
                              width: 1.5,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '[${entry.timestamp}]',
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isDark ? Colors.red.shade200 : Colors.red.shade800,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.red,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.warning_amber_rounded, size: 12, color: Colors.white),
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
                                      color: isDark ? Colors.red.shade200 : Colors.red.shade700,
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
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 10),
                              // Action options: Keep, Edit, Delete
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () => keepFlaggedLine(entry),
                                    icon: const Icon(Icons.check, size: 14, color: Colors.teal),
                                    label: const Text('Keep', style: TextStyle(color: Colors.teal, fontSize: 12)),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Colors.teal),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      minimumSize: const Size(0, 32),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton.icon(
                                    onPressed: () => editTranscriptLine(entry),
                                    icon: const Icon(Icons.edit_outlined, size: 14, color: Colors.blue),
                                    label: const Text('Edit', style: TextStyle(color: Colors.blue, fontSize: 12)),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Colors.blue),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      minimumSize: const Size(0, 32),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ElevatedButton.icon(
                                    onPressed: () => deleteTranscriptLine(entry),
                                    icon: const Icon(Icons.delete_outline, size: 14, color: Colors.white),
                                    label: const Text('Delete', style: TextStyle(color: Colors.white, fontSize: 12)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      minimumSize: const Size(0, 32),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      } else {
                        // Unflagged standard line
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white.withValues(alpha: 0.03) : const Color(0xFFF8FAFB),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
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
                                  icon: const Icon(Icons.edit_outlined, size: 16, color: Colors.grey),
                                  tooltip: 'Edit line',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () => editTranscriptLine(entry),
                                ),
                            ],
                          ),
                        );
                      }
                    }),
                  if (isRecording) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.teal),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Transcribing live speech line by line...',
                          style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: Colors.grey.shade600,
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
          // Captured Images Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.photo_library_outlined, color: Colors.teal),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Captured Board Images (${sessionCapturedImages.length})',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Quick sample image',
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        onPressed: addSampleImageQuickly,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (sessionCapturedImages.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.grey, size: 20),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'No board images captured yet in this lecture session. '
                              'Use "Capture Board Image" below.',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
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
                          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
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
                                Text(
                                  img.title,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                                const Spacer(),
                                Chip(
                                  label: Text(
                                    img.option.label,
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                                  ),
                                  padding: EdgeInsets.zero,
                                  backgroundColor: Colors.teal.withValues(alpha: 0.15),
                                ),
                                const SizedBox(width: 6),
                                IconButton(
                                  icon: const Icon(Icons.close, size: 18, color: Colors.red),
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
                            BoardPreviewWidget(
                              item: img,
                              compact: true,
                            ),
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
                      label: const Text('Capture Board Image (With Side Transcripts & 3 Options)'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Action Buttons: Save Session or Generate Notes
          Card(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 14),
                  // Button to Save whole session to Saved Inputs
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: saveSessionToSavedInputs,
                      icon: const Icon(Icons.bookmark_add),
                      label: const Text('Save Session to Saved Inputs'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: generateNotes,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Generate Demo Notes Now'),
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
