import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_helpers.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final feedbackController = TextEditingController();
  int rating = 4;

  @override
  void dispose() {
    feedbackController.dispose();
    super.dispose();
  }

  Future<void> submitFeedback() async {
    if (feedbackController.text.trim().isEmpty) {
      showMessage(context, 'Please enter some feedback first.');
      return;
    }

    final confirmed = await askConfirmation(
      context,
      title: 'Submit Feedback?',
      message: 'Submit this feedback for the demo session?',
      confirmText: 'Submit',
    );

    if (!mounted || !confirmed) return;

    feedbackController.clear();
    setState(() => rating = 4);
    showMessage(
      context,
      'Thank you! Feedback confirmed locally; it was not sent to a server.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Feedback')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          pageHeading(
            'Share Your Feedback',
            'Help improve the Smart Notes prototype',
          ),
          const Text(
            'How would you rate your experience?',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (index) {
              final selected = index < rating;
              return IconButton(
                tooltip: '${index + 1} star${index == 0 ? '' : 's'}',
                onPressed: () => setState(() => rating = index + 1),
                icon: Icon(
                  selected ? Icons.star : Icons.star_border,
                  color: AppTheme.warning,
                  size: 36,
                ),
              );
            }),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: feedbackController,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Your feedback',
              hintText: 'Tell us what worked well or what to improve...',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: submitFeedback,
              icon: const Icon(Icons.send),
              label: const Text('Submit Feedback'),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Feedback is only confirmed in this demo. It is not uploaded '
            'or sent to anyone.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}