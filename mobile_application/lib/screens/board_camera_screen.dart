import 'package:flutter/material.dart';
import '../data/demo_data.dart';
import '../models/board_image_item.dart';
import '../widgets/board_preview_widget.dart';
import '../widgets/ui_helpers.dart';

class BoardCameraScreen extends StatefulWidget {
  const BoardCameraScreen({
    super.key,
    this.isSessionMode = false,
    this.sessionTitle,
  });

  final bool isSessionMode;
  final String? sessionTitle;

  @override
  State<BoardCameraScreen> createState() => _BoardCameraScreenState();
}

class _BoardCameraScreenState extends State<BoardCameraScreen> {
  bool hasPreview = false;
  bool looksGoodClicked = false;
  late CapturedImageItem currentItem;

  @override
  void initState() {
    super.initState();
    _initDemoItem();
  }

  void _initDemoItem() {
    currentItem = CapturedImageItem(
      id: DemoData.nextInputId,
      title: 'Board Capture #${DemoData.nextInputId}',
      ocrText: '• Neural Network Architecture Overview\n'
          '• Step 1: Real-time Camera Feed (Glasses)\n'
          '• Step 2: YOLOv8 Face Anonymization Pipeline\n'
          '• Step 3: OCR Text Extraction & Whiteboard Analysis\n'
          '• Loss: L_privacy = λ · ||I_blur - I_orig||\n'
          '• Target Frame Latency: < 45ms\n'
          '• Status: Encryption Verified',
      option: BoardImageOption.both,
    );
  }

  void captureDemo() {
    setState(() {
      _initDemoItem();
      hasPreview = true;
      looksGoodClicked = false;
    });
    showMessage(context, 'Board image captured. Review preview.');
  }

  void onLooksGoodPressed() {
    setState(() {
      looksGoodClicked = true;
    });
    showMessage(
      context,
      'Image accepted! Now view image with transcripts at the side and choose an option.',
    );
  }

  void retakeImage() {
    setState(() {
      hasPreview = false;
      looksGoodClicked = false;
    });
  }

  Future<void> saveConfirmedImage() async {
    if (widget.isSessionMode) {
      Navigator.pop(context, currentItem);
      return;
    }

    final confirmed = await askConfirmation(
      context,
      title: 'Save Image Input?',
      message: 'Save this board capture (${currentItem.option.label}) to Saved Inputs?',
      confirmText: 'Save Input',
    );
    if (!mounted || !confirmed) return;

    final buffer = StringBuffer();
    buffer.writeln('Board Capture: ${currentItem.title}');
    buffer.writeln('Format Choice: ${currentItem.option.label}');
    if (currentItem.option != BoardImageOption.imageAsIs) {
      buffer.writeln('\nDetected OCR Transcripts:\n${currentItem.ocrText}');
    } else {
      buffer.writeln('\nVisual board image stored as raw visual.');
    }

    DemoData.addInput(
      title: currentItem.title,
      type: 'Board Image',
      content: buffer.toString(),
      capturedImages: [currentItem],
    );

    setState(() {
      hasPreview = false;
      looksGoodClicked = false;
    });
    if (mounted) {
      showMessage(context, 'Board image saved to Saved Inputs.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isSessionMode ? 'Capture Lecture Board' : 'Board Image Capture'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          pageHeading(
            widget.isSessionMode ? 'Workshop Lecture Capture' : 'Capture Board Image',
            looksGoodClicked
                ? 'Review image & transcripts with format options'
                : hasPreview
                    ? 'Verify if image looks good'
                    : 'Capture a board from your smart glasses',
          ),
          if (widget.isSessionMode && widget.sessionTitle != null) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.teal.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.teal.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.school_outlined, color: Colors.teal, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Session: ${widget.sessionTitle}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (!hasPreview) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Icon(
                      Icons.camera_alt_outlined,
                      size: 72,
                      color: Colors.teal,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Camera Feed Ready',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Press button below to simulate capturing a whiteboard from smart glasses.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: captureDemo,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Capture Board Image'),
                    ),
                  ],
                ),
              ),
            ),
          ] else if (!looksGoodClicked) ...[
            // State: Captured, preview shown, waiting for "Image looks good" or "Retake"
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.visibility_outlined, size: 16, color: Colors.blue),
                          SizedBox(width: 6),
                          Text(
                            'Step 1 of 2: Image Quality Check',
                            style: TextStyle(
                              color: Colors.blue,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    BoardPreviewWidget(
                      item: currentItem,
                      showOptionsSelector: false,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Does this board capture look clear and readable?',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      alignment: WrapAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: onLooksGoodPressed,
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text('Image Looks Good'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: retakeImage,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retake Image'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            // State: User clicked "Image looks good"!
            // Shows image with transcripts at side with 3 options (image as it, OCR, both)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle, color: Colors.green, size: 16),
                              SizedBox(width: 4),
                              Text(
                                'Image Looks Good',
                                style: TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Image & Transcripts Side-by-Side',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    BoardPreviewWidget(
                      item: currentItem,
                      showOptionsSelector: true,
                      onOptionChanged: (newOpt) {
                        setState(() {
                          currentItem.option = newOpt;
                        });
                      },
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: saveConfirmedImage,
                            icon: Icon(
                              widget.isSessionMode ? Icons.add_to_photos : Icons.save,
                            ),
                            label: Text(
                              widget.isSessionMode
                                  ? 'Add to Workshop Session'
                                  : 'Save to Saved Inputs',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 13),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: retakeImage,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retake'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Card(
            child: ListTile(
              leading: Icon(Icons.face_retouching_natural, color: Colors.teal),
              title: Text('YOLOv8 Face Anonymization'),
              subtitle: Text(
                'Faces and sensitive personal identifiers are detected and blurred on-device.',
              ),
              trailing: Chip(
                label: Text('Privacy Safe', style: TextStyle(fontSize: 11)),
              ),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.lock_outline, color: Colors.teal),
              title: Text('Encrypted Capture Storage'),
              subtitle: Text(
                'Extracted OCR text and raw captures are encrypted using AES-256.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
