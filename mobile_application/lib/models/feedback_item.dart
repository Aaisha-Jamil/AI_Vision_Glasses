// Represents feedback returned by the backend.
// userId is read-only client data; the backend derives ownership from the access token.
class FeedbackItem {
  const FeedbackItem({
    required this.id,
    required this.userId,
    required this.rating,
    required this.category,
    required this.createdAt,
    this.sessionId,
    this.noteId,
    this.comments,
  });

  final String id;
  final String userId;
  final int rating;
  final String category;
  final DateTime createdAt;
  final String? sessionId;
  final String? noteId;
  final String? comments;

  factory FeedbackItem.fromJson(Map<String, dynamic> json) {
    return FeedbackItem(
      id: json['id'].toString(),
      userId: json['user_id'].toString(),
      rating: (json['rating'] as num).toInt(),
      category: json['category'].toString(),
      createdAt: DateTime.parse(json['created_at'].toString()),
      sessionId: json['session_id']?.toString(),
      noteId: json['note_id']?.toString(),
      comments: json['comments']?.toString(),
    );
  }
}
