import 'board_image_item.dart';
import 'transcript_line_item.dart';

class SavedInput {
  SavedInput({
    required this.id,
    required this.title,
    required this.type,
    required this.content,
    this.notesGenerated = false,
    this.capturedImages = const [],
    this.audioTranscripts = const [],
    List<TranscriptLineItem>? transcriptLines,
    this.audioDuration,
    DateTime? createdAt,
  })  : transcriptLines = transcriptLines ?? [],
        createdAt = createdAt ?? DateTime.now();

  final int id;
  String title;
  final String type;
  final String content;
  final DateTime createdAt;
  bool notesGenerated;
  final List<CapturedImageItem> capturedImages;

  /// Flat formatted strings used for notes generation (legacy/compat).
  final List<String> audioTranscripts;

  /// Full structured transcript lines with flagging metadata.
  /// Mutable so Saved Inputs can keep/edit/delete individual lines.
  final List<TranscriptLineItem> transcriptLines;

  final String? audioDuration;
}
