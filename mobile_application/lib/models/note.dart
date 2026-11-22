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
    this.docxUrl,
    this.docxPath,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int id;
  String? noteId;
  String? sessionId;
  String? userId;
  bool? isSatisfactory;
  String title;
  String content;
  String type;
  String? docxUrl;
  String? docxPath;
  final DateTime createdAt;
}

