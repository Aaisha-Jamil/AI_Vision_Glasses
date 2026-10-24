import 'package:flutter/material.dart';
import '../data/demo_data.dart';
import '../models/board_image_item.dart';
import '../models/saved_input.dart';
import '../models/transcript_line_item.dart';
import '../widgets/board_preview_widget.dart';
import '../widgets/ui_helpers.dart';
import 'saved_notes_screen.dart';

class SavedInputsScreen extends StatefulWidget {
  const SavedInputsScreen({super.key});

  @override
  State<SavedInputsScreen> createState() => _SavedInputsScreenState();
}

class _SavedInputsScreenState extends State<SavedInputsScreen> {
  void generateNotes(SavedInput input) {
    final created = DemoData.generateNotesForInput(input);
    setState(() {});
    if (created) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Notes generated for "${input.title}".'),
          action: SnackBarAction(
            label: 'View Notes',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SavedNotesScreen()),
              );
            },
          ),
        ),
      );
    } else {
      showMessage(context, 'Notes were already generated for this input.');
    }
  }

  Future<void> deleteSession(SavedInput input) async {
    final isWorkshop = input.type == 'Workshop Session';
    final confirmed = await askConfirmation(
      context,
      title: isWorkshop ? 'Delete Session?' : 'Delete Input?',
      message: isWorkshop
          ? 'Are you sure you want to delete session "${input.title}" and its saved transcripts and captured images?'
          : 'Are you sure you want to delete "${input.title}"?',
      confirmText: 'Delete',
    );

    if (!mounted || !confirmed) return;

    DemoData.deleteInput(input.id);
    setState(() {});

    if (mounted) {
      showMessage(
        context,
        isWorkshop
            ? 'Session "${input.title}" deleted from Saved Inputs.'
            : '"${input.title}" deleted.',
      );
    }
  }

  // ── Transcript line management (mirrors AudioStudioScreen behaviour) ──────

  void keepFlaggedLine(TranscriptLineItem line) {
    setState(() => line.isFlagged = false);
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
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
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
      showMessage(context, 'Transcript line updated.');
    }
    controller.dispose();
  }

  Future<void> deleteTranscriptLine(
      SavedInput input, TranscriptLineItem line) async {
    final confirmed = await askConfirmation(
      context,
      title: 'Delete Line?',
      message: 'Remove this transcript line from the saved session?',
      confirmText: 'Delete',
    );
    if (!mounted || !confirmed) return;
    setState(() => input.transcriptLines.remove(line));
    showMessage(context, 'Transcript line deleted.');
  }

  // ── Widget builders ───────────────────────────────────────────────────────

  Widget _buildTranscriptSection(
      BuildContext context, SavedInput input, bool isDark, ThemeData theme) {
    final lines = input.transcriptLines;

    // Fallback: if structured lines are absent (old sessions), use plain strings
    if (lines.isEmpty && input.audioTranscripts.isNotEmpty) {
      return _buildPlainTranscriptFallback(context, input, theme);
    }
    if (lines.isEmpty) return const SizedBox.shrink();

    final hasFlagged = lines.any((l) => l.isFlagged);

    // ── Build an interleaved list: transcript lines + inline image cards ──
    // Images that have a capturedAtSecond are inserted right after the last
    // transcript line whose secondTrigger <= capturedAtSecond.
    // Images with capturedAtSecond before all lines (targetIndex == -1) are
    // placed BEFORE the first line using the special key -1.
    // Images without capturedAtSecond (legacy) are appended at the end.
    final images = List<CapturedImageItem>.from(input.capturedImages);
    final legacyImages = images.where((img) => img.capturedAtSecond == null).toList();
    final timedImages = images.where((img) => img.capturedAtSecond != null).toList();

    // Map: line index -> list of images to show AFTER that line.
    // Key -1 = images to display BEFORE the very first transcript line.
    final Map<int, List<CapturedImageItem>> imagesByLineIndex = {};
    for (final img in timedImages) {
      // Find the last line whose secondTrigger <= capturedAtSecond
      int targetIndex = -1; // -1 means before all lines
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].secondTrigger <= img.capturedAtSecond!) {
          targetIndex = i;
        }
      }
      // Keep -1 for pre-first-line images; use last matching index otherwise
      imagesByLineIndex.putIfAbsent(targetIndex, () => []).add(img);
    }

    // Build widgets list
    final List<Widget> items = [];

    // Images captured before any transcript line (key == -1)
    final preLineImgs = imagesByLineIndex[-1];
    if (preLineImgs != null) {
      for (final img in preLineImgs) {
        items.add(_buildInlineCapturedImage(img, isDark, theme));
      }
    }

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      items.add(
        line.isFlagged
            ? _buildFlaggedLine(line, isDark)
            : _buildCleanLine(line, input, isDark, theme),
      );
      // Insert any images captured after this line
      final imgsHere = imagesByLineIndex[i];
      if (imgsHere != null) {
        for (final img in imgsHere) {
          items.add(_buildInlineCapturedImage(img, isDark, theme));
        }
      }
    }

    // Append legacy images (no capturedAtSecond) at the end
    for (final img in legacyImages) {
      items.add(_buildInlineCapturedImage(img, isDark, theme));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        const Row(
          children: [
            Icon(Icons.mic, size: 16, color: Colors.teal),
            SizedBox(width: 6),
            Text(
              'Lecture Audio Transcripts & Board Captures',
              style:
                  TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Noise banner when flagged lines present
        if (hasFlagged) ...[
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              border:
                  Border.all(color: Colors.red.withValues(alpha: 0.2)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.red, size: 16),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Flagged noise lines are highlighted below. Use Keep, Edit, or Delete to manage.',
                    style: TextStyle(fontSize: 11, color: Colors.red),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        // Interleaved transcript lines and inline image cards
        ...items,
        const SizedBox(height: 8),
      ],
    );
  }

  /// Inline image card displayed within the transcript stream.
  Widget _buildInlineCapturedImage(
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
          // Caption bar
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.12),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(10),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.camera_alt_outlined,
                    size: 15, color: Colors.teal),
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
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
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
          // Board preview
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

  /// Fallback for sessions saved before the structured-lines feature.
  Widget _buildPlainTranscriptFallback(
      BuildContext context, SavedInput input, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.mic, size: 16, color: Colors.teal),
            SizedBox(width: 6),
            Text(
              'Lecture Audio Transcripts',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: input.audioTranscripts.map((line) {
              final match =
                  RegExp(r'^\[(\d{2}:\d{2})\]\s*(.*)$').firstMatch(line);
              if (match != null) {
                final time = match.group(1)!;
                final text = match.group(2)!;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
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
                        child: Text(text,
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(line, style: const TextStyle(fontSize: 12)),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _buildFlaggedLine(TranscriptLineItem line, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            isDark ? const Color(0xFF381A20) : const Color(0xFFFFEBEE),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                    color:
                        isDark ? Colors.red.shade200 : Colors.red.shade800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 12, color: Colors.white),
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
                  color:
                      isDark ? Colors.red.shade200 : Colors.red.shade700,
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
          // Keep / Edit / Delete action row
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: () => keepFlaggedLine(line),
                icon: const Icon(Icons.check, size: 14, color: Colors.teal),
                label: const Text('Keep',
                    style: TextStyle(color: Colors.teal, fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.teal),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: const Size(0, 32),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => editTranscriptLine(line),
                icon: const Icon(Icons.edit_outlined,
                    size: 14, color: Colors.blue),
                label: const Text('Edit',
                    style: TextStyle(color: Colors.blue, fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.blue),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: const Size(0, 32),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () => _requestDeleteLine(line),
                icon: const Icon(Icons.delete_outline,
                    size: 14, color: Colors.white),
                label: const Text('Delete',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: const Size(0, 32),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCleanLine(TranscriptLineItem line, SavedInput input,
      bool isDark, ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color:
                theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            icon: const Icon(Icons.edit_outlined,
                size: 16, color: Colors.grey),
            tooltip: 'Edit line',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => editTranscriptLine(line),
          ),
        ],
      ),
    );
  }

  Future<void> _requestDeleteLine(TranscriptLineItem line) async {
    // Find the input that owns this line
    final input = DemoData.savedInputs.firstWhere(
      (i) => i.transcriptLines.contains(line),
      orElse: () => throw StateError('Line not found in any input'),
    );
    await deleteTranscriptLine(input, line);
  }

  @override
  Widget build(BuildContext context) {
    final inputs = DemoData.savedInputs;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved Inputs'),
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
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          pageHeading(
            'Saved Inputs & Sessions',
            'Workshop lecture sessions, audio transcripts, and board captures',
          ),
          if (inputs.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Column(
                  children: [
                    Icon(Icons.inventory_2_outlined,
                        size: 56, color: Colors.teal),
                    SizedBox(height: 14),
                    Text(
                      'No saved inputs yet',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Record a workshop lecture or capture board images in ' 
                      'Multi-Input Notes Studio and save the session',
                    
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ...inputs.map((input) {
            final isWorkshop = input.type == 'Workshop Session';

            return Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header row
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          backgroundColor: isWorkshop
                              ? Colors.teal.withValues(alpha: 0.15)
                              : theme.colorScheme.primary
                                  .withValues(alpha: 0.15),
                          child: Icon(
                            isWorkshop
                                ? Icons.school_outlined
                                : input.type == 'Audio'
                                    ? Icons.graphic_eq
                                    : Icons.image_outlined,
                            color: isWorkshop
                                ? Colors.teal
                                : theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                input.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isWorkshop
                                          ? Colors.teal
                                              .withValues(alpha: 0.15)
                                          : theme.colorScheme
                                              .surfaceContainerHighest,
                                      borderRadius:
                                          BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      input.type,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isWorkshop
                                            ? Colors.teal
                                            : null,
                                      ),
                                    ),
                                  ),
                                  if (input.audioDuration != null) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      '• Duration: ${input.audioDuration}',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: isWorkshop
                              ? 'Delete Session'
                              : 'Delete Input',
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: () => deleteSession(input),
                        ),
                      ],
                    ),
                    const Divider(height: 20),

                    // ── Workshop Session ──
                    if (isWorkshop) ...[
                      // Transcript with board images interleaved inline
                      // at the exact positions where they were captured.
                      _buildTranscriptSection(
                          context, input, isDark, theme),
                    ] else ...[
                      // Individual non-session input
                      if (input.capturedImages.isNotEmpty) ...[
                        ...input.capturedImages.map((img) => Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 10),
                              child: BoardPreviewWidget(
                                item: img,
                                compact: true,
                              ),
                            )),
                      ] else ...[
                        Text(input.content,
                            style: const TextStyle(fontSize: 13)),
                      ],
                    ],

                    const SizedBox(height: 12),
                    // Notes generated status
                    Row(
                      children: [
                        Icon(
                          input.notesGenerated
                              ? Icons.check_circle
                              : Icons.pending_outlined,
                          color: input.notesGenerated
                              ? Colors.green
                              : Colors.orange,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            input.notesGenerated
                                ? 'Notes generated in Saved Notes'
                                : 'Notes not generated yet',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: input.notesGenerated
                                ? null
                                : () => generateNotes(input),
                            icon: const Icon(Icons.auto_awesome),
                            label: Text(
                              input.notesGenerated
                                  ? 'Notes Already Generated'
                                  : 'Generate Notes',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: () => deleteSession(input),
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          label: Text(
                            isWorkshop ? 'Delete Session' : 'Delete',
                            style:
                                const TextStyle(color: Colors.red),
                          ),
                          style: OutlinedButton.styleFrom(
                            side:
                                const BorderSide(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
