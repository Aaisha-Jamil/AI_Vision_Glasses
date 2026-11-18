import 'package:flutter/material.dart';
import '../data/demo_data.dart';
import '../widgets/ui_helpers.dart';

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  bool temporaryHistory = true;

  Future<void> deleteHistory() async {
    final confirmed = await askConfirmation(
      context,
      title: 'Delete All Demo Notes?',
      message: 'This removes notes currently held in this app session.',
      confirmText: 'Delete All',
    );
    if (!mounted || !confirmed) return;
    DemoData.notes.clear();
    DemoData.savedInputs.clear();
    DemoData.refreshCount();
    setState(() {});
    showMessage(context, 'Session notes cleared.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Centre')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          pageHeading(
            'Privacy Controls',
            'Review how the prototype handles your notes',
          ),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.history),
              title: const Text('Temporary history preference'),
              subtitle: const Text(
                'This preference is only a demo; it does not '
                'automatically delete notes.',
              ),
              value: temporaryHistory,
              onChanged: (value) {
                setState(() => temporaryHistory = value);
              },
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete session history'),
              subtitle: Text(
                '${DemoData.notes.length} notes currently in memory',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: deleteHistory,
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Data protection'),
              subtitle: Text(
                'This demo does not implement encryption, secure '
                'authentication, or permanent private storage.',
              ),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.face_retouching_natural),
              title: Text('Face anonymization'),
              subtitle: Text(
                'YOLOv8 detection and image anonymization are '
                'not active in this prototype.',
              ),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.mic_none),
              title: Text('Audio privacy'),
              subtitle: Text(
                'The Audio Studio timer does not access the microphone '
                'or record actual audio.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
