import 'package:flutter/material.dart';
import '../data/demo_data.dart';
import '../services/auth_service.dart';
import '../widgets/ui_helpers.dart';
import 'audio_studio_screen.dart';
import 'feedback_screen.dart';
import 'login_screen.dart';
import 'privacy_screen.dart';
import 'saved_inputs_screen.dart';
import 'saved_notes_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.themeNotifier,
    required this.email,
  });

  final ValueNotifier<bool> themeNotifier;
  final String email;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    // currentUserId was set by login / AuthGate; widget.email is only for display
    DemoData.loadFromSupabase().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> logout(BuildContext context) async {
    final confirmed = await askConfirmation(
      context,
      title: 'Logout',
      message: 'Do you want to leave the dashboard?',
      confirmText: 'Logout',
    );
    if (!confirmed || !context.mounted) return;
    // revoke the session and delete the stored token, or the app logs in again by itself
    try {
      await AuthService.instance.logout();
    } catch (_) {}
    if (!context.mounted) return;
    DemoData.currentUserId = '';
    DemoData.savedInputs.clear();
    DemoData.notes.clear();
    DemoData.refreshCount();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          themeNotifier: widget.themeNotifier,
        ),
      ),
      (route) => false,
    );
  }

  void openPage(BuildContext context, Widget page) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Notes Hub'),
        actions: [
          IconButton(
            tooltip: 'Backend Server Connection',
            icon: const Icon(Icons.router_outlined),
            onPressed: () => showServerConfigDialog(context),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: widget.themeNotifier,
            builder: (context, isDark, child) {
              return IconButton(
                tooltip: isDark
                    ? 'Switch to Light Mode'
                    : 'Switch to Dark Mode',
                onPressed: () {
                  widget.themeNotifier.value = !widget.themeNotifier.value;
                },
                icon: Icon(
                  isDark ? Icons.light_mode : Icons.dark_mode,
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Logout',
            onPressed: () => logout(context),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          pageHeading(
            'Welcome to Smart Notes',
            'Privacy Preserving Smart System for Notes Taking',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 26,
                    child: Icon(Icons.person_outline, size: 30),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Current session',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(widget.email),
                        const SizedBox(height: 4),
                        const Text(
                          'Demo mode',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          featureCard(
            context: context,
            icon: Icons.mic_none,
            title: 'Multi-Input Notes Studio',
            subtitle: 'Live audio recording, board capture, and notes studio',
            onTap: () => openPage(context, const AudioStudioScreen()),
          ),
          featureCard(
            context: context,
            icon: Icons.inventory_2_outlined,
            title: 'Saved Inputs',
            subtitle: 'View saved images and audio transcriptions',
            onTap: () => openPage(context, const SavedInputsScreen()),
          ),
          ValueListenableBuilder<int>(
            valueListenable: DemoData.noteCount,
            builder: (context, count, child) {
              return featureCard(
                context: context,
                icon: Icons.folder_open_outlined,
                title: 'Saved Notes',
                subtitle: '$count notes in this session',
                onTap: () => openPage(context, const SavedNotesScreen()),
              );
            },
          ),
          featureCard(
            context: context,
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Centre',
            subtitle: 'Privacy options and history controls',
            onTap: () => openPage(context, const PrivacyScreen()),
          ),
          featureCard(
            context: context,
            icon: Icons.feedback_outlined,
            title: 'Feedback',
            subtitle: 'Share feedback about this prototype',
            onTap: () => openPage(context, const FeedbackScreen()),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Devices Connection',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.bluetooth, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 10),
                      const Expanded(child: Text('Bluetooth: Hardware status')),
                      const Chip(label: Text('Ready')),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.battery_5_bar, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 10),
                      const Expanded(child: Text('Battery: Smart Glasses')),
                      const Text('85%'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Hardware connection and battery information '
                    'are not implemented in this demo.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}