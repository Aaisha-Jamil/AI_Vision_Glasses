class DemoNote {
  DemoNote({
    required this.id,
    required this.title,
    required this.content,
    required this.type,
    this.noteId,
    this.sessionId,
    this.userId,
    this.isSatisfactory,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int id;
  String? noteId;
  String? sessionId;
  String? userId;
  bool? isSatisfactory;
  String title;
  String content;
  final String type;
  final DateTime createdAt;
}

