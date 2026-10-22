import 'package:flutter/foundation.dart';
import '../models/board_image_item.dart';
import '../models/note.dart';
import '../models/saved_input.dart';
import '../models/transcript_line_item.dart';

class DemoData {
  static final List<SavedInput> savedInputs = [];
  static int nextInputId = 1;

  static SavedInput addInput({
    required String title,
    required String type,
    required String content,
    List<CapturedImageItem> capturedImages = const [],
    List<String> audioTranscripts = const [],
    String? audioDuration,
  }) {
    final input = SavedInput(
      id: nextInputId++,
      title: title,
      type: type,
      content: content,
      capturedImages: capturedImages,
      audioTranscripts: audioTranscripts,
      audioDuration: audioDuration,
    );
    savedInputs.insert(0, input);
    return input;
  }

  static SavedInput addSessionInput({
    required String title,
    required List<String> audioTranscripts,
    required List<CapturedImageItem> capturedImages,
    required String audioDuration,
    List<TranscriptLineItem>? allTranscriptLines,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('Workshop Lecture Session: $title');
    buffer.writeln('Recording duration: $audioDuration');
    buffer.writeln('Transcripts recorded: ${audioTranscripts.length}');
    buffer.writeln('Board images captured: ${capturedImages.length}');

    final input = SavedInput(
      id: nextInputId++,
      title: title,
      type: 'Workshop Session',
      content: buffer.toString(),
      capturedImages: List.from(capturedImages),
      audioTranscripts: List.from(audioTranscripts),
      transcriptLines: allTranscriptLines != null
          ? List.from(allTranscriptLines)
          : [],
      audioDuration: audioDuration,
    );
    savedInputs.insert(0, input);
    return input;
  }

  static bool deleteInput(int id) {
    final index = savedInputs.indexWhere((element) => element.id == id);
    if (index != -1) {
      savedInputs.removeAt(index);
      return true;
    }
    return false;
  }

  static bool generateNotesForInput(SavedInput input) {
    if (input.notesGenerated) return false;

    if (input.type == 'Workshop Session') {
      final buffer = StringBuffer();
      buffer.writeln('=== WORKSHOP LECTURE SUMMARY ===');
      buffer.writeln('Session: ${input.title}');
      if (input.audioDuration != null) {
        buffer.writeln('Duration: ${input.audioDuration}\n');
      }

      buffer.writeln('--- Audio Lecture Transcripts ---');
      if (input.audioTranscripts.isNotEmpty) {
        for (final line in input.audioTranscripts) {
          buffer.writeln(line);
        }
      } else {
        buffer.writeln('No audio transcripts captured.');
      }

      buffer.writeln('\n--- Board Captures & Extracted Knowledge ---');
      if (input.capturedImages.isNotEmpty) {
        for (var i = 0; i < input.capturedImages.length; i++) {
          final img = input.capturedImages[i];
          buffer.writeln('Capture #${i + 1}: ${img.title} [Mode: ${img.option.label}]');
          if (img.option != BoardImageOption.imageAsIs) {
            buffer.writeln('OCR Text:\n${img.ocrText.trim()}');
          }
          if (img.option == BoardImageOption.imageAsIs) {
            buffer.writeln('(Visual board graphic saved with raw capture data)');
          }
          buffer.writeln('');
        }
      } else {
        buffer.writeln('No board images attached.');
      }

      buffer.writeln('--- Key Action Items & Concepts ---');
      buffer.writeln('• Review core architectural components outlined on board.');
      buffer.writeln('• Cross-reference audio highlights with board diagram equations.');
      buffer.writeln('• Prepare follow-up questions for next lecture.');

      addNote(
        title: '${input.title} - Comprehensive Notes',
        content: buffer.toString(),
        type: 'Workshop Session Notes',
      );
    } else {
      addNote(
        title: '${input.title} Notes',
        content: input.content,
        type: input.type,
      );
    }

    input.notesGenerated = true;
    return true;
  }

  static final List<DemoNote> notes = [];
  static int nextId = 1;
  static final ValueNotifier<int> noteCount = ValueNotifier<int>(0);

  static void refreshCount() {
    noteCount.value = notes.length;
  }

  static void addNote({
    required String title,
    required String content,
    required String type,
  }) {
    notes.insert(
      0,
      DemoNote(
        id: nextId++,
        title: title,
        content: content,
        type: type,
      ),
    );
    refreshCount();
  }
}
