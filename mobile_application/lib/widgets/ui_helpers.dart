import 'dart:async';

import 'package:flutter/material.dart';
import '../data/demo_data.dart';
import '../models/note.dart';
import '../models/saved_input.dart';
import '../screens/saved_notes_screen.dart';
import '../services/api_config.dart';
import '../services/audio_service.dart';
import '../theme/app_theme.dart';

void showMessage(BuildContext context, String message) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger != null) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

/// Runs [task] behind a blocking progress dialog that shows [title], [hint] and the
/// elapsed time, then closes it. Errors from [task] are rethrown to the caller.
Future<T> runWithProgressDialog<T>(
  BuildContext context, {
  required String title,
  String? hint,
  required Future<T> Function() task,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: _ProgressDialog(title: title, hint: hint),
    ),
  );
  try {
    return await task();
  } finally {
    navigator.pop();
  }
}

class _ProgressDialog extends StatefulWidget {
  const _ProgressDialog({required this.title, this.hint});

  final String title;
  final String? hint;

  @override
  State<_ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<_ProgressDialog> {
  final _watch = Stopwatch()..start();
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _watch.elapsed.inSeconds;
    final elapsed = '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          const CircularProgressIndicator(),
          const SizedBox(height: 18),
          Text(widget.title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 6),
          Text('Elapsed: $elapsed', style: const TextStyle(fontSize: 13)),
          if (widget.hint != null) ...[
            const SizedBox(height: 10),
            Text(widget.hint!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: AppTheme.mutedText)),
          ],
        ],
      ),
    );
  }
}

/// Generates AI notes for [input] behind the progress dialog. Returns the note, or
/// null if notes already existed or generation failed (the reason is shown).
Future<DemoNote?> generateNotesWithProgress(BuildContext context, SavedInput input) async {
  try {
    final note = await runWithProgressDialog<DemoNote?>(
      context,
      title: 'Generating notes…',
      hint: 'Gemini is writing your notes from the transcript and board images. '
          'This usually takes 1–3 minutes - please keep the app open.',
      task: () => DemoData.generateAiNotesForInput(input),
    );
    if (note == null && context.mounted) {
      showMessage(context, 'Notes were already generated for this input.');
    }
    return note;
  } catch (e) {
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Notes could not be generated'),
          content: Text(e.toString()),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    }
    return null;
  }
}

Future<bool> askConfirmation(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = 'Confirm',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  // Yield one frame so the dialog route cleans up before caller updates state
  await Future.delayed(Duration.zero);
  return result ?? false;
}

Widget pageHeading(String title, String subtitle) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: const TextStyle(fontSize: 14)),
      ],
    ),
  );
}

Widget featureCard({
  required BuildContext context,
  required IconData icon,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
}) {
  final color = Theme.of(context).colorScheme.primary;
  return Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(subtitle),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ),
  );
}

Future<void> showServerConfigDialog(BuildContext context) async {
  final config = ApiConfig();
  final controller = TextEditingController(text: config.baseUrl);
  String? testStatus;
  bool isTesting = false;

  await showDialog(
    context: context,
    builder: (dialogCtx) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.router_outlined, color: AppTheme.primary(context)),
                const SizedBox(width: 10),
                const Text('Backend Server IP'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enter your laptop or server Wi-Fi address (e.g. http://192.168.1.50:8000) so this mobile device can connect to the Python pipeline.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'FastAPI Backend URL',
                      hintText: 'http://192.168.x.x:8000',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: isTesting
                            ? null
                            : () async {
                                setState(() {
                                  isTesting = true;
                                  testStatus = 'Testing connection...';
                                });
                                config.setBaseUrl(controller.text);
                                final res = await AudioService().checkHealth();
                                setState(() {
                                  isTesting = false;
                                  if (res['online'] == true) {
                                    testStatus = '✅ Connected! Server is online.';
                                  } else {
                                    testStatus = '❌ Could not reach server. Check IP and Wi-Fi.';
                                  }
                                });
                              },
                        icon: isTesting
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sensors, size: 16),
                        label: const Text('Test Ping'),
                      ),
                    ],
                  ),
                  if (testStatus != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      testStatus!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: testStatus!.startsWith('✅') ? AppTheme.success : AppTheme.danger,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  config.setBaseUrl(controller.text);
                  Navigator.pop(dialogCtx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Server URL set to: ${config.baseUrl}')),
                  );
                },
                child: const Text('Save URL'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> showStorageQuotaExceededDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: AppTheme.danger, size: 28),
          SizedBox(width: 10),
          Expanded(child: Text('Storage Limit Reached (2/2)')),
        ],
      ),
      content: const Text(
        'Due to limited Supabase database storage, a maximum of 2 unfinished sessions can be saved per user.\n\n'
        'Please generate notes for an existing session or delete an unfinished session from "Saved Inputs" before saving a new one.',
        style: TextStyle(fontSize: 14, height: 1.4),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primary(context)),
          child: const Text('Understood'),
        ),
      ],
    ),
  );
}

/// Scenario 1: Dialog workflow after document has been generated.
/// Prompts user to keep or discard saved inputs, explains storage recommendation,
/// requires confirmation before deletion, and retains notes safely.
Future<bool> showPostNoteGenerationRetentionDialog({
  required BuildContext context,
  required SavedInput session,
  required DemoNote note,
  VoidCallback? onDone,
}) async {
  // Step 1: Prompt Keep or Discard
  final choice = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.auto_awesome, color: AppTheme.primary(context)),
          const SizedBox(width: 8),
          const Text('Document Generated'),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Notes for "${session.title}" have been successfully generated and saved to Saved Notes.',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: () => openNotePreview(dialogCtx, note),
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  label: const Text('Preview notes'),
                ),
                if ((note.docxUrl ?? '').isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => downloadNoteDocx(dialogCtx, note),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Download .docx'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Would you like to keep or discard the saved session inputs (audio recordings & board captures)?',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.warning.withValues(alpha: 0.3)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 18, color: AppTheme.warning),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Since your notes have already been generated and database storage is limited, deleting the session inputs is recommended.',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(dialogCtx, 'keep'),
          icon: const Icon(Icons.schedule, size: 16),
          label: const Text('Keep Inputs (7 Days)'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(dialogCtx, 'discard'),
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('Discard Inputs (Recommended)'),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
        ),
      ],
    ),
  );

  if (!context.mounted || choice == null) return false;

  if (choice == 'discard') {
    // Step 2: Show a clear confirmation message before deletion
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (confirmCtx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppTheme.danger),
            SizedBox(width: 8),
            Text('Confirm Discard Inputs'),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to discard the saved inputs for "${session.title}"?',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              const Text(
                'This will permanently delete the raw audio recordings and board captures from Supabase storage.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                '• The generated document in Saved Notes will NOT be affected and remains safely stored.',
                style: TextStyle(fontSize: 13, color: AppTheme.primary(context), fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(confirmCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(confirmCtx, true),
            icon: const Icon(Icons.delete_forever),
            label: const Text('Confirm Discard'),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
          ),
        ],
      ),
    );

    if (!context.mounted || confirmed != true) return false;

    // Discard session inputs from Supabase & memory
    DemoData.applyRetentionDecision(
      session,
      discardInputs: true,
      note: note,
    );

    onDone?.call();

    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: const Text('Session inputs discarded from Supabase. Generated document is preserved.'),
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
    return true;
  } else {
    // Keep inputs temporarily for 7 days
    DemoData.applyRetentionDecision(
      session,
      discardInputs: false,
      note: note,
    );

    onDone?.call();

    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: const Text('Inputs retained. They will be automatically deleted after 7 days.'),
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
    return true;
  }
}
