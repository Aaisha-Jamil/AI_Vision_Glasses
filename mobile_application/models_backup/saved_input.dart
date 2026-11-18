import 'board_image_item.dart';
import 'transcript_line_item.dart';

class SavedInput {
  SavedInput({
    required this.id,
    required this.title,
    required this.type,
    required this.content,
    String? sessionId,
    String? userId,
    this.notesGenerated = false,
    this.capturedImages = const [],
    this.audioTranscripts = const [],
    List<TranscriptLineItem>? transcriptLines,
    this.audioDuration,
    this.expiresAt,
    this.isSatisfactory,
    DateTime? createdAt,
  })  : sessionId = sessionId ?? 'session_${DateTime.now().millisecondsSinceEpoch}',
        userId = userId ?? 'user_demo@aivision.com',
        transcriptLines = transcriptLines ?? [],
        createdAt = createdAt ?? DateTime.now();

  final int id;
  final String sessionId;
  final String userId;
  String title;
  String type;
  String content;
  final DateTime createdAt;
  bool notesGenerated;
  DateTime? expiresAt;
  bool? isSatisfactory;
  List<CapturedImageItem> capturedImages;

  /// Flat formatted strings used for notes generation (legacy/compat).
  List<String> audioTranscripts;

  /// Full structured transcript lines with flagging metadata.
  /// Mutable so Saved Inputs can keep/edit/delete individual lines.
  List<TranscriptLineItem> transcriptLines;

  String? audioDuration;

  /// Whether this session has passed its 7-day automatic deletion window.
  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// Remaining days until auto-deletion.
  int? get daysRemaining {
    if (expiresAt == null) return null;
    final diff = expiresAt!.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }

  /// User-friendly label for retention status.
  String get retentionLabel {
    if (expiresAt == null) {
      return notesGenerated ? 'Notes generated' : 'Active Raw Session';
    }
    final days = daysRemaining ?? 0;
    if (days <= 0) return 'Auto-deletes today';
    return 'Auto-deletes in $days day${days == 1 ? '' : 's'}';
  }
}
