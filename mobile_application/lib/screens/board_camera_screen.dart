import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../data/demo_data.dart';
import '../models/board_image_item.dart';
import '../services/vision_service.dart';
import '../widgets/board_preview_widget.dart';
import '../widgets/ui_helpers.dart';

class BoardCameraScreen extends StatefulWidget {
  const BoardCameraScreen({
    super.key,
    this.isSessionMode = false,
    this.sessionTitle,
    this.sessionId,
  });

  final bool isSessionMode;
  final String? sessionTitle;
  final String? sessionId;

  @override
  State<BoardCameraScreen> createState() => _BoardCameraScreenState();
}

class _BoardCameraScreenState extends State<BoardCameraScreen> {
  bool hasPreview = false;
  bool looksGoodClicked = false;
  bool isProcessing = false;
  String processingStatus = '';
  late CapturedImageItem currentItem;
  final ImagePicker _picker = ImagePicker();

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
          '• Step 1: Real-time Camera Feed (Glasses/Mobile)\n'
          '• Step 2: YOLOv8 Face Anonymization Pipeline\n'
          '• Step 3: OCR Text Extraction & Whiteboard Analysis\n'
          '• Loss: L_privacy = λ · ||I_blur - I_orig||\n'
          '• Target Frame Latency: < 45ms\n'
          '• Status: Encryption & Privacy Verified',
      option: BoardImageOption.both,
    );
  }

  Future<void> captureWithCamera() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 92,
      );
      if (photo != null) {
        await _processPickedImage(photo);
      }
    } catch (e) {
      if (mounted) showMessage(context, 'Camera access error: $e');
    }
  }

  Future<void> pickFromGallery() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 92,
      );
      if (photo != null) {
        await _processPickedImage(photo);
      }
    } catch (e) {
      if (mounted) showMessage(context, 'Gallery access error: $e');
    }
  }

  Future<void> _processPickedImage(XFile imageFile) async {
    setState(() {
      isProcessing = true;
      processingStatus = 'Running YOLOv8 Privacy Blur & EasyOCR Extraction...';
    });

    try {
      final effectiveSessionId = widget.sessionId ??
          (widget.sessionTitle != null && widget.sessionTitle!.isNotEmpty
              ? widget.sessionTitle!
              : 'sess_${DateTime.now().millisecondsSinceEpoch}');
      final result = await VisionService().processSnapshot(
        imageFile,
        sessionId: effectiveSessionId,
      );

      final newId = DemoData.nextInputId;
      final ocrText = result['extracted_text'] as String? ?? 'No text detected';
      final localPath = result['local_path'] as String?;
      final remoteUrl = result['full_blurred_image_url'] as String?;
      final snapshotId = result['snapshot_id'] as String?;
      final conf = (result['confidence_score'] as num?)?.toDouble();
      final peopleDetected = (result['people_detected'] as num?)?.toInt() ?? 0;

      setState(() {
        currentItem = CapturedImageItem(
          id: newId,
          title: 'Board Capture #$newId',
          ocrText: ocrText,
          option: BoardImageOption.both,
          localImagePath: localPath,
          remoteImageUrl: remoteUrl,
          snapshotId: snapshotId,
          confidenceScore: conf,
          peopleDetected: peopleDetected,
        );
        hasPreview = true;
        looksGoodClicked = false;
        isProcessing = false;
      });

      if (mounted) {
        showMessage(
          context,
          peopleDetected > 0
              ? 'YOLOv8 Shield blurred $peopleDetected person(s). Review preview.'
              : 'Image processed & privacy verified. Review preview.',
        );
      }
    } catch (e) {
      setState(() => isProcessing = false);
      if (mounted) {
        showMessage(context, 'Pipeline processing error: $e');
      }
    }
  }

  void captureDemo() {
    setState(() {
      _initDemoItem();
      hasPreview = true;
      looksGoodClicked = false;
    });
    showMessage(context, 'Sample board image loaded for testing.');
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

    // Scenario 2: Enforce 2 unfinished sessions limit per user
    if (!DemoData.canAddUnfinishedSession) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red),
              SizedBox(width: 8),
              Text('Storage Limit Reached'),
            ],
          ),
          content: const Text(
            'You already have 2 unfinished sessions saved. Due to Supabase database storage limitations, '
            'a maximum of 2 unfinished sessions can be saved per user.\n\n'
            'Please generate notes for an existing session or delete an unfinished session before saving a new one.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
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

    if (currentItem.snapshotId != null) {
      final prefStr = currentItem.option == BoardImageOption.imageAsIs
          ? 'IMAGE_ONLY'
          : currentItem.option == BoardImageOption.ocr
              ? 'OCR_TEXT_ONLY'
              : 'BOTH';
      VisionService().updatePreference(currentItem.snapshotId!, prefStr);
    }

    final sid = widget.sessionId ?? 'sess_${DateTime.now().millisecondsSinceEpoch}';

    DemoData.addInput(
      title: currentItem.title,
      type: 'Board Image',
      sessionId: sid,
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
        actions: [
          IconButton(
            tooltip: 'Server Connection Settings',
            icon: const Icon(Icons.router_outlined),
            onPressed: () => showServerConfigDialog(context),
          ),
        ],
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
                    : 'Capture a board from your smart glasses or mobile camera',
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
          if (isProcessing) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    const CircularProgressIndicator(strokeWidth: 3),
                    const SizedBox(height: 20),
                    Text(
                      processingStatus,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Anonymizing faces with YOLOv8 & extracting text with EasyOCR...',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ] else if (!hasPreview) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Icon(
                      Icons.camera_alt_outlined,
                      size: 64,
                      color: Colors.teal,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Mobile Camera Ready',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Capture whiteboard notes directly from your phone camera or select a photo from your gallery.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: captureWithCamera,
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Take Photo (Mobile Camera)'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: pickFromGallery,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Upload Photo from Gallery'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: captureDemo,
                      icon: const Icon(Icons.science_outlined, size: 18),
                      label: const Text('Simulate Glasses Sample'),
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
