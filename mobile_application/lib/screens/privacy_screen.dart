import 'package:flutter/material.dart';
import '../data/demo_data.dart';
import '../widgets/ui_helpers.dart';

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  Future<void> deleteHistory() async {
    final confirmed = await askConfirmation(
      context,
      title: 'Clear Local Session Memory?',
      message: 'This clears all notes and session inputs currently loaded into active memory.',
      confirmText: 'Clear Memory',
    );
    if (!mounted || !confirmed) return;
    DemoData.notes.clear();
    DemoData.savedInputs.clear();
    DemoData.refreshCount();
    setState(() {});
    showMessage(context, 'Local session memory cleared.');
  }

  Widget _buildPrivacyPillar({
    required IconData icon,
    required String title,
    required String description,
    required Color color,
    required bool isDark,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: color.withValues(alpha: 0.25),
          width: 1.2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Centre')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          pageHeading(
            'Privacy & Data Protection',
            'How your vision, audio, and notes are protected',
          ),
          _buildPrivacyPillar(
            icon: Icons.face_retouching_natural,
            title: 'On-Device Face Anonymization',
            description:
                'Every snapshot captured by the smart glasses is run through our YOLOv8 face detector before anything is saved or processed. Faces of classmates and instructors are automatically blurred so unblurred facial data never persists.',
            color: Colors.blueAccent,
            isDark: isDark,
          ),
          _buildPrivacyPillar(
            icon: Icons.graphic_eq,
            title: 'Semantic Noise & Off-Topic Filtering',
            description:
                'The audio pipeline divides recordings into brief chunks and applies embedding-based semantic scoring. Ambient noise, coughing, and off-topic conversations are automatically flagged in red so you can review, edit, or exclude them from final notes.',
            color: Colors.teal,
            isDark: isDark,
          ),
          _buildPrivacyPillar(
            icon: Icons.timer_outlined,
            title: '7-Day Retention & Instant Purge',
            description:
                'Raw session inputs (audio chunks and board snapshots) are subject to a strict 7-day automatic expiry. Alternatively, you can tap "Discard Inputs Now" as soon as your notes are generated to purge all raw media while keeping your synthesized document.',
            color: Colors.orange,
            isDark: isDark,
          ),
          _buildPrivacyPillar(
            icon: Icons.lock_outline,
            title: 'Isolated Cloud Storage with RLS',
            description:
                'All database rows in Supabase are guarded with Row-Level Security (RLS) policies. Only your authenticated user account can access or modify your sessions and notes.',
            color: Colors.green,
            isDark: isDark,
          ),
          const SizedBox(height: 14),
          const Text(
            'Local Storage Controls',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Clear All Local Notes & Sessions'),
              subtitle: Text(
                '${DemoData.notes.length} note(s), ${DemoData.savedInputs.length} input(s) currently loaded in memory',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: deleteHistory,
            ),
          ),
        ],
      ),
    );
  }
}
