class DemoNote {
  DemoNote({
    required this.id,
    required this.title,
    required this.content,
    required this.type,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int id;
  String title;
  String content;
  final String type;
  final DateTime createdAt;
}
