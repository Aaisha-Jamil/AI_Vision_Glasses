import 'package:flutter/material.dart';

import '../services/feedback_service.dart';
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
  String selectedCategory = 'General';
  bool isSubmitting = false;

  final List<String> categories = [
    'General',
    'Notes',
    'Audio Transcription',
    'Image Recognition',
  ];

  @override
  void dispose() {
    feedbackController.dispose();
    super.dispose();
  }

  Future<void> submitFeedback() async {
    final comments = feedbackController.text.trim();

    if (comments.isEmpty) {
      showMessage(context, 'Please enter some feedback first.');
      return;
    }

    if (isSubmitting) return;

    final confirmed = await askConfirmation(
      context,
      title: 'Submit Feedback?',
      message: 'Submit this feedback for the app?',
      confirmText: 'Submit',
    );

    if (!mounted || !confirmed) return;

    setState(() => isSubmitting = true);

    try {
      await FeedbackService.instance.submit(
        rating: rating,
        category: selectedCategory,
        comments: comments,
      );

      if (!mounted) return;

      feedbackController.clear();

      setState(() {
        rating = 4;
        selectedCategory = 'General';
      });

      showMessage(
        context,
        'Thank you! Your feedback was submitted successfully.',
      );
    } catch (error) {
      if (!mounted) return;

      showMessage(
        context,
        error.toString(),
      );
    } finally {
      if (mounted) {
        setState(() => isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feedback'),
      ),
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
                onPressed: isSubmitting
                    ? null
                    : () => setState(() => rating = index + 1),
                icon: Icon(
                  selected ? Icons.star : Icons.star_border,
                  color: AppTheme.warning,
                  size: 36,
                ),
              );
            }),
          ),

          const SizedBox(height: 16),

          const Text(
            'Feedback Category',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),

          const SizedBox(height: 8),

          DropdownButtonFormField<String>(
            initialValue: selectedCategory, // Replaced 'value' with 'initialValue'
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.category_outlined),
              border: OutlineInputBorder(),
            ),
            items: categories.map((category) {
              return DropdownMenuItem<String>(
                value: category,
                child: Text(category),
              );
            }).toList(),
            onChanged: isSubmitting
                ? null
                : (value) {
                    if (value != null) {
                      setState(() => selectedCategory = value);
                    }
                  },
          ),

          const SizedBox(height: 16),

          TextField(
            controller: feedbackController,
            maxLines: 6,
            enabled: !isSubmitting,
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
              onPressed: isSubmitting ? null : submitFeedback,
              icon: isSubmitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.send),
              label: Text(
                isSubmitting ? 'Submitting...' : 'Submit Feedback',
              ),
            ),
          ),

          const SizedBox(height: 12),

          const Text(
            'Your feedback is sent securely through the backend '
            'and associated with your authenticated account.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}