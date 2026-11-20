enum BoardImageOption {
  imageAsIs,
  ocr,
  both,
}

extension BoardImageOptionExtension on BoardImageOption {
  String get label {
    switch (this) {
      case BoardImageOption.imageAsIs:
        return 'Image as it is';
      case BoardImageOption.ocr:
        return 'OCR';
      case BoardImageOption.both:
        return 'Both';
    }
  }

  String get description {
    switch (this) {
      case BoardImageOption.imageAsIs:
        return 'Keep original board image only';
      case BoardImageOption.ocr:
        return 'Keep extracted text transcript only';
      case BoardImageOption.both:
        return 'Keep both image and OCR text';
    }
  }
}

class CapturedImageItem {
  CapturedImageItem({
    required this.id,
    required this.title,
    required this.ocrText,
    this.option = BoardImageOption.both,
    this.diagramType = 'architecture',
    this.capturedAtSecond,
    this.localImagePath,
    this.remoteImageUrl,
    this.snapshotId,
    this.confidenceScore,
    this.peopleDetected = 0,
    DateTime? capturedAt,
  }) : capturedAt = capturedAt ?? DateTime.now() {
    // OCR still running on the server: every copy of this capture (screens copy
    // items) is registered, so all of them get the text when it arrives.
    if (ocrText == ocrPendingText && snapshotId != null) pendingOcr.add(this);
  }

  /// Same text as the backend's OCR_PENDING_TEXT (main.py).
  static const String ocrPendingText = 'OCR processing…';

  /// Items whose OCR text has not arrived yet (see VisionService.watchOcr).
  static final List<CapturedImageItem> pendingOcr = [];

  bool get isOcrPending => ocrText == ocrPendingText;

  final int id;
  final String title;

  // ocrText, remoteImageUrl, confidenceScore, peopleDetected change when the user
  // crops the image and the backend re-runs OCR on it.
  String ocrText;
  BoardImageOption option;
  final String diagramType;
  final DateTime capturedAt;

  /// The recording second at which this image was captured during a session.
  final int? capturedAtSecond;

  /// Local file path on the device (from camera/gallery)
  final String? localImagePath;

  /// Remote processed URL (from FastAPI / Supabase)
  String? remoteImageUrl;

  /// Database/Pipeline snapshot identifier
  final String? snapshotId;

  /// OCR confidence score (0.0 to 1.0)
  double? confidenceScore;

  /// Number of people detected and privacy-blurred by YOLOv8
  int peopleDetected;
}
