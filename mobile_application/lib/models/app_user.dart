// Represents the authenticated app user returned by the FastAPI authentication API.
// The user ID and role must come from a verified identity-provider token.
class AppUser {
  const AppUser({
    required this.id,
    required this.email,
    required this.role,
    this.fullName,
  });

  final String id;
  final String email;
  final String role;
  final String? fullName;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'].toString(),
      email: (json['email'] ?? '').toString(),
      role: (json['role'] ?? 'user').toString(),
      fullName: json['full_name']?.toString(),
    );
  }
}
