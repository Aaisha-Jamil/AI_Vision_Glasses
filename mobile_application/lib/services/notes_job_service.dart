import 'dart:async';

import 'package:flutter/material.dart';

import '../data/demo_data.dart';
import '../models/saved_input.dart';
import '../widgets/ui_helpers.dart';

/// One notes generation running in the background.
class NotesJob {
  NotesJob(this.input) : startedAt = DateTime.now();

  final SavedInput input;
  final DateTime startedAt;
}

/// Runs notes generation in the background, so the user can keep using the app.
/// [NotesProgressBanner] shows the running jobs at the top of every screen; when a
/// job ends, a snackbar says so ("Review" opens the Keep / Discard inputs dialog).
class NotesJobs extends ChangeNotifier {
  NotesJobs._();

  static final NotesJobs instance = NotesJobs._();

  /// Set on MaterialApp, so jobs can show snackbars / dialogs on any screen.
  static final navigatorKey = GlobalKey<NavigatorState>();
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  final Map<String, NotesJob> _jobs = {};

  List<NotesJob> get running => _jobs.values.toList(growable: false);

  bool isRunning(SavedInput input) => _jobs.containsKey(input.sessionId);

  /// Starts generating notes for [input] and returns at once.
  /// [onChanged] runs when the job ends and after the Keep / Discard choice
  /// (callers refresh their screen there; check `mounted` first).
  void start(SavedInput input, {VoidCallback? onChanged}) {
    if (isRunning(input)) {
      _snack('Notes for "${input.title}" are already being generated.');
      return;
    }
    _jobs[input.sessionId] = NotesJob(input);
    notifyListeners();
    _snack('Generating notes for "${input.title}" in the background. '
        'You can keep using the app.');
    unawaited(_run(input, onChanged));
  }

  Future<void> _run(SavedInput input, VoidCallback? onChanged) async {
    try {
      final note = await DemoData.generateAiNotesForInput(input);
      _finish(input, onChanged);
      if (note == null) {
        _snack('Notes were already generated for "${input.title}".');
        return;
      }
      _snack(
        'Notes ready: "${input.title}"',
        actionLabel: 'Review',
        duration: const Duration(seconds: 12),
        onAction: () {
          final ctx = navigatorKey.currentContext;
          if (ctx == null) return;
          // Scenario 1: document generated -> keep or discard the inputs
          showPostNoteGenerationRetentionDialog(
            context: ctx,
            session: input,
            note: note,
            onDone: onChanged,
          );
        },
      );
    } catch (e) {
      _finish(input, onChanged);
      _snack(
        'Notes could not be generated for "${input.title}".',
        actionLabel: 'Details',
        duration: const Duration(seconds: 12),
        onAction: () {
          final ctx = navigatorKey.currentContext;
          if (ctx == null) return;
          showDialog<void>(
            context: ctx,
            builder: (dCtx) => AlertDialog(
              title: const Text('Notes could not be generated'),
              content: Text(e.toString()),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(dCtx),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        },
      );
    }
  }

  void _finish(SavedInput input, VoidCallback? onChanged) {
    _jobs.remove(input.sessionId);
    notifyListeners();
    onChanged?.call();
  }

  void _snack(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 4),
  }) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      duration: duration,
      action: actionLabel == null || onAction == null
          ? null
          : SnackBarAction(label: actionLabel, onPressed: onAction),
    ));
  }
}

/// Wraps the whole app (MaterialApp.builder). While notes are being generated, a
/// slim strip with a progress bar and the elapsed time sits at the top of every
/// screen; the screen itself stays usable below it.
class NotesProgressBanner extends StatefulWidget {
  const NotesProgressBanner({super.key, required this.child});

  final Widget child;

  @override
  State<NotesProgressBanner> createState() => _NotesProgressBannerState();
}

class _NotesProgressBannerState extends State<NotesProgressBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    NotesJobs.instance.addListener(_onJobsChanged);
    _onJobsChanged();
  }

  @override
  void dispose() {
    NotesJobs.instance.removeListener(_onJobsChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _onJobsChanged() {
    final busy = NotesJobs.instance.running.isNotEmpty;
    if (busy && _ticker == null) {
      // once a second, for the elapsed time
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!busy) {
      _ticker?.cancel();
      _ticker = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final jobs = NotesJobs.instance.running;
    if (jobs.isEmpty) return widget.child;

    final first = jobs.first;
    final s = DateTime.now().difference(first.startedAt).inSeconds;
    final elapsed = '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    final label = jobs.length == 1
        ? 'Generating notes: ${first.input.title}'
        : 'Generating notes for ${jobs.length} sessions';
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Material(
          color: scheme.primary,
          child: SafeArea(
            bottom: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                  child: Row(
                    children: [
                      Icon(Icons.auto_awesome, size: 16, color: scheme.onPrimary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        elapsed,
                        style: TextStyle(color: scheme.onPrimary, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                LinearProgressIndicator(
                  minHeight: 3,
                  color: scheme.onPrimary,
                  backgroundColor: scheme.onPrimary.withValues(alpha: 0.25),
                ),
              ],
            ),
          ),
        ),
        // the strip already covers the status bar, so the screen must not pad for it
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
