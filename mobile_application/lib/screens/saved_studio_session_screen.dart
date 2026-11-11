import 'package:flutter/material.dart';
import '../data/demo_data.dart';
import '../models/board_image_item.dart';
import '../models/saved_input.dart';
import '../models/transcript_line_item.dart';
import '../widgets/board_preview_widget.dart';
import '../widgets/ui_helpers.dart';
import 'saved_notes_screen.dart';
import 'audio_studio_screen.dart';

enum StudioViewTab {
  synchronizedFeed,
  audioTranscripts,
  boardCaptures,
}

/// A dedicated screen providing the exact same rich, multi-modal layout
/// as the Multi-Input Notes Studio for any previously captured or submitted session.
class SavedStudioSessionScreen extends StatefulWidget {
  const SavedStudioSessionScreen({
    super.key,
    required this.input,
  });

  final SavedInput input;

  @override
  State<SavedStudioSessionScreen> createState() =>
      _SavedStudioSessionScreenState();
}

class _SavedStudioSessionScreenState extends State<SavedStudioSessionScreen> {
  StudioViewTab _currentTab = StudioViewTab.synchronizedFeed;

  SavedInput get input => widget.input;

  void keepFlaggedLine(TranscriptLineItem line) {
    setState(() => line.isFlagged = false);
    DemoData.updateTranscriptLine(line);
    showMessage(context, 'Line kept — noise flag removed.');
  }

  Future<void> editTranscriptLine(TranscriptLineItem line) async {
    final controller = TextEditingController(text: line.text);
    bool unflagOnSave = line.isFlagged;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Icon(
                line.isFlagged ? Icons.warning_amber_rounded : Icons.edit_note,
                color: line.isFlagged ? Colors.red : Colors.teal,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  line.isFlagged
                      ? 'Edit Flagged Noise / Line'
                      : 'Edit Transcript Line',
                ),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Timestamp: [${line.timestamp}]',
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
                if (line.isFlagged) ...[
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Mark as clean speech (remove red flag)',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
        line.text = controller.text.trim();
        if (line.isFlagged && unflagOnSave) {
          line.isFlagged = false;
        }
      });
      DemoData.updateTranscriptLine(line);
      showMessage(context, 'Transcript line updated in Supabase.');
    }
    controller.dispose();
  }

  Future<void> deleteTranscriptLine(TranscriptLineItem line) async {
    final confirmed = await askConfirmation(
      context,
      title: 'Delete Line?',
      message: 'Remove this transcript line from the saved session?',
      confirmText: 'Delete',
    );
    if (!mounted || !confirmed) return;
    setState(() => input.transcriptLines.remove(line));
    DemoData.deleteTranscriptLine(line);
    showMessage(context, 'Transcript line deleted from Supabase.');
  }

  Future<void> generateNotes() async {
    final note = DemoData.generateNotesForInput(input);
    setState(() {});

    if (note == null) {
      showMessage(context, 'Notes were already generated for this input.');
      return;
    }

    if (!mounted) return;

    // Scenario 1: Document Has Been Generated
    // Prompt Keep or Discard, recommend discard due to limited storage,
    // show confirmation dialog, and retain the generated document safely.
    await showPostNoteGenerationRetentionDialog(
      context: context,
      session: input,
      note: note,
      onDone: () {
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> discardInputsNow() async {
    final confirmed = await askConfirmation(
      context,
      title: 'Discard Saved Inputs?',
      message:
          'Are you sure you want to discard the audio recordings and board captures for "${input.title}"?\n\n'
          'The generated document in Saved Notes will NOT be affected and remains safely stored.',
      confirmText: 'Discard Inputs',
    );
    if (!mounted || !confirmed) return;

    final note = DemoData.notes.where((n) => n.id == input.id).firstOrNull ??
        DemoData.notes.where((n) => n.title == input.title).firstOrNull;

    DemoData.applyRetentionDecision(
      input,
      discardInputs: true,
      note: note,
    );
    setState(() {});
    showMessage(context, 'Session inputs discarded from Supabase. Generated document is preserved.');
  }

  Future<void> deleteSession() async {
    final confirmed = await askConfirmation(
      context,
      title: 'Delete Session?',
      message:
          'Are you sure you want to permanently delete session "${input.title}" and its transcripts and images from Supabase?',
      confirmText: 'Delete',
    );
    if (!mounted || !confirmed) return;
    DemoData.deleteInput(input.id);
    if (mounted) {
      Navigator.pop(context);
      showMessage(context, 'Session deleted from Supabase.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final lines = input.transcriptLines;
    final images = input.capturedImages;
    final hasFlagged = lines.any((l) => l.isFlagged);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              input.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const Text(
              'Multi-Input Notes Studio Inspector',
              style: TextStyle(fontSize: 11, color: Colors.teal),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'View Saved Notes',
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SavedNotesScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Delete Session',
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: deleteSession,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          // ── Studio Hero Header Card (Mirrors Multi-Input Notes Studio) ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                children: [
                  const Icon(
                    Icons.graphic_eq,
                    size: 64,
                    color: Colors.teal,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    input.audioDuration ?? '00:00',
                    style: const TextStyle(
                      fontSize: 42,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.teal.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.teal.withValues(alpha: 0.3)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_outline,
                                size: 14, color: Colors.teal),
                            SizedBox(width: 5),
                            Text(
                              'STUDIO CAPTURE COMPLETED',
                              style: TextStyle(
                                color: Colors.teal,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Transcripts: ${lines.isNotEmpty ? lines.length : input.audioTranscripts.length} lines',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Board Captures: ${images.length} images',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Viewing captured session inputs stored in Supabase PostgreSQL.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Studio View Mode Selector Tabs ──
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _buildTabButton(
                    tab: StudioViewTab.synchronizedFeed,
                    label: 'Synchronized Feed',
                    icon: Icons.sync_alt,
                  ),
                ),
                Expanded(
                  child: _buildTabButton(
                    tab: StudioViewTab.audioTranscripts,
                    label: 'Transcripts (${lines.isNotEmpty ? lines.length : input.audioTranscripts.length})',
                    icon: Icons.mic,
                  ),
                ),
                Expanded(
                  child: _buildTabButton(
                    tab: StudioViewTab.boardCaptures,
                    label: 'Board Images (${images.length})',
                    icon: Icons.photo_library,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Content Display based on selected tab ──
          if (_currentTab == StudioViewTab.synchronizedFeed)
            _buildSynchronizedFeedCard(isDark, theme)
          else if (_currentTab == StudioViewTab.audioTranscripts)
            _buildAudioTranscriptsCard(isDark, theme, hasFlagged)
          else
            _buildBoardCapturesCard(isDark, theme),

          const SizedBox(height: 20),

          // ── Session Meta & Retention Info Card ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.cloud_done_outlined, size: 18, color: Colors.teal),
                      SizedBox(width: 8),
                      Text(
                        'Supabase Cloud Storage & Retention',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        input.notesGenerated ? Icons.check_circle : Icons.pending_outlined,
                        color: input.notesGenerated ? Colors.green : Colors.orange,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        input.notesGenerated
                            ? 'Comprehensive Notes Generated'
                            : 'Notes Pending Generation',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      if (input.expiresAt != null)
                        Text(
                          input.retentionLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: (input.daysRemaining ?? 0) <= 1
                                ? Colors.red
                                : Colors.orange,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Session ID: ${input.sessionId} • User: ${input.userId}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // ── Bottom Action Buttons ──
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (!input.notesGenerated) ...[
                ElevatedButton.icon(
                  onPressed: generateNotes,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Generate Comprehensive Notes'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AudioStudioScreen(resumedSession: input),
                      ),
                    ).then((_) {
                      if (mounted) setState(() {});
                    });
                  },
                  icon: const Icon(Icons.edit_note, size: 18),
                  label: const Text('Resume in Studio'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.teal.withValues(alpha: 0.18),
                    foregroundColor: Colors.teal,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  ),
                ),
              ],
              if (input.notesGenerated && input.expiresAt != null)
                FilledButton.icon(
                  onPressed: discardInputsNow,
                  icon: const Icon(Icons.delete_sweep, size: 18),
                  label: const Text('Discard Inputs Now'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildTabButton({
    required StudioViewTab tab,
    required String label,
    required IconData icon,
  }) {
    final isSelected = _currentTab == tab;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _currentTab = tab),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.teal : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? Colors.white : Colors.grey,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected ? Colors.white : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 1. SYNCHRONIZED FEED (Speech lines + inline captures chronologically aligned)
  // ===========================================================================
  Widget _buildSynchronizedFeedCard(bool isDark, ThemeData theme) {
    final lines = input.transcriptLines;
    final images = input.capturedImages;

    final List<Widget> items = [];

    if (lines.isNotEmpty) {
      final timedImages = images.where((img) => img.capturedAtSecond != null).toList();
      final legacyImages = images.where((img) => img.capturedAtSecond == null).toList();

      final Map<int, List<CapturedImageItem>> imagesByLine = {};
      for (final img in timedImages) {
        int targetIdx = -1;
        for (int i = 0; i < lines.length; i++) {
          if (lines[i].secondTrigger <= img.capturedAtSecond!) {
            targetIdx = i;
          }
        }
        imagesByLine.putIfAbsent(targetIdx, () => []).add(img);
      }

      // Pre-first-line images
      final preImgs = imagesByLine[-1];
      if (preImgs != null) {
        for (final img in preImgs) {
          items.add(_buildStudioInlineImage(img, isDark, theme));
        }
      }

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        items.add(
          line.isFlagged
              ? _buildFlaggedLineWidget(line, isDark)
              : _buildCleanLineWidget(line, isDark, theme),
        );
        final imgs = imagesByLine[i];
        if (imgs != null) {
          for (final img in imgs) {
            items.add(_buildStudioInlineImage(img, isDark, theme));
          }
        }
      }

      for (final img in legacyImages) {
        items.add(_buildStudioInlineImage(img, isDark, theme));
      }
    } else if (input.audioTranscripts.isNotEmpty) {
      // Plain transcripts fallback
      for (final raw in input.audioTranscripts) {
        items.add(_buildPlainLineWidget(raw, theme));
      }
      for (final img in images) {
        items.add(_buildStudioInlineImage(img, isDark, theme));
      }
    } else if (images.isNotEmpty) {
      for (final img in images) {
        items.add(_buildStudioInlineImage(img, isDark, theme));
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sync_alt, color: Colors.teal),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Synchronized Audio & Board Feed',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${items.length} EVENTS',
                    style: const TextStyle(
                      color: Colors.teal,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (items.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No transcripts or board captures found in this session.'),
                ),
              )
            else
              ...items,
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 2. AUDIO TRANSCRIPTS TAB
  // ===========================================================================
  Widget _buildAudioTranscriptsCard(bool isDark, ThemeData theme, bool hasFlagged) {
    final lines = input.transcriptLines;

    return Card(
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
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${lines.isNotEmpty ? lines.length : input.audioTranscripts.length} LINES',
                    style: const TextStyle(
                      color: Colors.teal,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (hasFlagged) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.red, size: 16),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Flagged noise lines are highlighted in red below. Use Keep, Edit, or Delete to manage.',
                        style: TextStyle(fontSize: 11, color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (lines.isNotEmpty)
              ...lines.map((l) => l.isFlagged
                  ? _buildFlaggedLineWidget(l, isDark)
                  : _buildCleanLineWidget(l, isDark, theme))
            else if (input.audioTranscripts.isNotEmpty)
              ...input.audioTranscripts.map((t) => _buildPlainLineWidget(t, theme))
            else
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text('No audio transcripts captured in this session.'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 3. BOARD CAPTURES TAB
  // ===========================================================================
  Widget _buildBoardCapturesCard(bool isDark, ThemeData theme) {
    final images = input.capturedImages;

    return Card(
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
                    'Captured Board Images (${images.length})',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (images.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Text(
                    'No board images attached to this session.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            else
              ...images.asMap().entries.map((entry) {
                final idx = entry.key;
                final img = entry.value;
                return Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.teal.withValues(alpha: 0.4),
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Caption Bar
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.teal.withValues(alpha: 0.12),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.camera_alt_outlined, size: 16, color: Colors.teal),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                img.title.isNotEmpty ? img.title : 'Board Capture #${idx + 1}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: Colors.teal,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.teal.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                img.option.label,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.teal,
                                ),
                              ),
                            ),
                            if (img.capturedAtSecond != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                '@ ${(img.capturedAtSecond! ~/ 60).toString().padLeft(2, '0')}:${(img.capturedAtSecond! % 60).toString().padLeft(2, '0')}',
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: BoardPreviewWidget(
                          item: img,
                          compact: false,
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  // ── Helper Sub-Widgets (Exact match with Studio Screen) ────────────────────

  Widget _buildStudioInlineImage(
      CapturedImageItem img, bool isDark, ThemeData theme) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.teal.withValues(alpha: 0.45),
          width: 1.5,
        ),
        color: isDark
            ? Colors.teal.withValues(alpha: 0.06)
            : Colors.teal.withValues(alpha: 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.12),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(
              children: [
                const Icon(Icons.camera_alt_outlined, size: 15, color: Colors.teal),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    img.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: Colors.teal,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    img.option.label,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.teal,
                    ),
                  ),
                ),
                if (img.capturedAtSecond != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            child: BoardPreviewWidget(
              item: img,
              compact: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlaggedLineWidget(TranscriptLineItem line, bool isDark) {
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
                  '[${line.timestamp}]',
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
                line.flagReason,
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
            line.text,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: () => keepFlaggedLine(line),
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
                onPressed: () => editTranscriptLine(line),
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
                onPressed: () => deleteTranscriptLine(line),
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
  }

  Widget _buildCleanLineWidget(TranscriptLineItem line, bool isDark, ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.03) : const Color(0xFFF8FAFB),
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
              '[${line.timestamp}]',
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
              line.text,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16, color: Colors.grey),
            tooltip: 'Edit line',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => editTranscriptLine(line),
          ),
        ],
      ),
    );
  }

  Widget _buildPlainLineWidget(String raw, ThemeData theme) {
    final match = RegExp(r'^\[(\d{2}:\d{2})\]\s*(.*)$').firstMatch(raw);
    final time = match != null ? match.group(1)! : '00:00';
    final text = match != null ? match.group(2)! : raw;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '[$time]',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.teal,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
