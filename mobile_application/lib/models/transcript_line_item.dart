class TranscriptLineItem {
  TranscriptLineItem({
    required this.id,
    required this.timestamp,
    required this.text,
    this.isFlagged = false,
    this.flagReason = 'Ambient Noise / Side Speech',
    this.secondTrigger = 0,
  });

  final String id;
  final String timestamp;
  String text;
  bool isFlagged;
  String flagReason;
  final int secondTrigger;

  String get formatted => isFlagged ? '[$timestamp] [FLAGGED NOISE] $text' : '[$timestamp] $text';

  TranscriptLineItem copyWith({
    String? id,
    String? timestamp,
    String? text,
    bool? isFlagged,
    String? flagReason,
    int? secondTrigger,
  }) {
    return TranscriptLineItem(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      text: text ?? this.text,
      isFlagged: isFlagged ?? this.isFlagged,
      flagReason: flagReason ?? this.flagReason,
      secondTrigger: secondTrigger ?? this.secondTrigger,
    );
  }
}
