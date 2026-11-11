import 'package:flutter/material.dart';
import '../data/demo_data.dart';
import '../models/note.dart';
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

  Future<void> previewNote(DemoNote note) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(note.title),
        content: SingleChildScrollView(
          child: SelectableText(note.content),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              editNote(note);
            },
            child: const Text('Edit'),
          ),
        ],
      ),
    );
  }

  void requestExport(String format) {
    showMessage(
      context,
      '$format export is not implemented yet. '
      'Your notes remain securely stored in Supabase.',
    );
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
                      'Create demo notes in Audio Studio or '
                      'Board Image Capture.',
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
                            color: Colors.red,
                          ),
                          label: const Text('Delete'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
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
