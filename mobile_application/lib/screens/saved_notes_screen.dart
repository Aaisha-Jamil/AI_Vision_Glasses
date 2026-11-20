import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/demo_data.dart';
import '../models/note.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_helpers.dart';

class SavedNotesScreen extends StatefulWidget {
  const SavedNotesScreen({super.key});

  @override
  State<SavedNotesScreen> createState() => _SavedNotesScreenState();
}

class _SavedNotesScreenState extends State<SavedNotesScreen> {
  void refresh() => setState(() {});

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    await DemoData.loadFromSupabase();
    if (mounted) refresh();
  }

  Future<void> editNote(DemoNote note) async {
    final titleController = TextEditingController(text: note.title);
    final contentController = TextEditingController(text: note.content);
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit Note'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentController,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Note content',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (save == true) {
      note.title = titleController.text.trim().isEmpty
          ? 'Untitled Note'
          : titleController.text.trim();
      note.content = contentController.text;
      await DemoData.updateNote(note);
      refresh();
      if (mounted) {
        showMessage(context, 'Note updated in Supabase.');
      }
    }
    titleController.dispose();
    contentController.dispose();
  }

  Future<void> deleteNote(DemoNote note) async {
    final confirmed = await askConfirmation(
      context,
      title: 'Delete Note?',
      message: 'Delete "${note.title}" permanently from Supabase?',
      confirmText: 'Delete',
    );
    if (!mounted || !confirmed) return;
    await DemoData.deleteNote(note.id);
    refresh();
    if (mounted) {
      showMessage(context, 'Note deleted from Supabase.');
    }
  }

  Future<void> previewNote(DemoNote note) =>
      openNotePreview(context, note, onEdit: () => editNote(note));

  Future<void> downloadDocx(DemoNote note) => downloadNoteDocx(context, note);

  void requestExport(String format) {
    if (format == 'Markdown') {
      if (DemoData.notes.isEmpty) {
        showMessage(context, 'No notes available to export.');
        return;
      }
      showMessage(
        context,
        'Exporting Markdown for ${DemoData.notes.length} note(s). Markdown structure is preserved.',
      );
    } else if (format == 'DOCX') {
      final docxNotes = DemoData.notes.where((n) => n.docxUrl != null && n.docxUrl!.isNotEmpty).toList();
      if (docxNotes.isNotEmpty) {
        showMessage(
          context,
          'Found ${docxNotes.length} synthesized .docx document(s) in cloud storage/local disk.',
        );
      } else {
        showMessage(
          context,
          'Generate notes from a lecture session to synthesize a Word .docx document.',
        );
      }
    } else {
      showMessage(
        context,
        '$format export: Your synthesized notes remain securely stored in Supabase.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved Notes'),
        actions: [
          IconButton(
            tooltip: 'Refresh from Supabase',
            icon: const Icon(Icons.refresh),
            onPressed: _loadNotes,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadNotes,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            pageHeading(
              'Your Notes',
              'Notes are synchronized and securely stored in Supabase',
            ),
          if (DemoData.notes.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.note_alt_outlined, size: 54),
                    SizedBox(height: 12),
                    Text(
                      'No notes saved yet',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Generate notes in Multi-Input Notes Studio or '
                      'Saved Inputs from your recorded lectures.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ...DemoData.notes.map(
            (note) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Icon(Icons.description_outlined),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              note.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(note.type),
                    const SizedBox(height: 8),
                    Text(
                      note.content,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => previewNote(note),
                          icon: const Icon(Icons.visibility_outlined),
                          label: const Text('Preview'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => editNote(note),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => deleteNote(note),
                          icon: const Icon(
                            Icons.delete_outline,
                            color: AppTheme.danger,
                          ),
                          label: const Text('Delete'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.danger,
                          ),
                        ),
                        if (note.docxUrl != null && note.docxUrl!.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () => downloadDocx(note),
                            icon: Icon(Icons.download, color: AppTheme.primary(context)),
                            label: const Text('Download .docx'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.primary(context),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Export options',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => requestExport('PDF'),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('Export PDF'),
              ),
              OutlinedButton.icon(
                onPressed: () => requestExport('DOCX'),
                icon: const Icon(Icons.description),
                label: const Text('Export DOCX'),
              ),
              OutlinedButton.icon(
                onPressed: () => requestExport('Markdown'),
                icon: const Icon(Icons.code),
                label: const Text('Export Markdown'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Export buttons are placeholders; they do not create files.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      ),
    );
  }
}

/// Opens the full-page preview of [note] (rendered Markdown + Download .docx).
Future<void> openNotePreview(BuildContext context, DemoNote note, {VoidCallback? onEdit}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (ctx) => _NotePreviewPage(
        note: note,
        onDownload: () => downloadNoteDocx(ctx, note),
        onEdit: onEdit,
      ),
    ),
  );
}

/// Opens the note's .docx URL; the browser / phone downloads or opens it directly.
Future<void> downloadNoteDocx(BuildContext context, DemoNote note) async {
  final url = note.docxUrl ?? '';
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    showMessage(
      context,
      url.isEmpty
          ? 'No .docx document is associated with this note.'
          : 'This .docx was not uploaded to cloud storage, so it cannot be downloaded '
              'on this device (it is on the server at: $url).',
    );
    return;
  }
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) showMessage(context, 'Could not open the download link.');
}

/// Full-page preview of a note, rendered from its Markdown (the same content as the
/// .docx; Word styling differs), with a Download .docx button.
class _NotePreviewPage extends StatelessWidget {
  const _NotePreviewPage({
    required this.note,
    required this.onDownload,
    required this.onEdit,
  });

  final DemoNote note;
  final Future<void> Function() onDownload;
  final VoidCallback? onEdit;

  bool get _hasDocx => (note.docxUrl ?? '').isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(note.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (onEdit != null)
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () {
                Navigator.pop(context);
                onEdit!();
              },
            ),
          if (_hasDocx)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: onDownload,
                icon: const Icon(Icons.download),
                label: const Text('.docx'),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Markdown(
              data: note.content,
              selectable: true,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              onTapLink: (text, href, title) {
                final uri = href == null ? null : Uri.tryParse(href);
                if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
              },
            ),
          ),
        ),
      ),
      bottomNavigationBar: _hasDocx
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.download),
                  label: const Text('Download Word document (.docx)'),
                ),
              ),
            )
          : null,
    );
  }
}
