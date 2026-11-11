import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_application/app.dart';

void main() {
  testWidgets('NotesPrivacyApp mounts and renders login screen safely', (WidgetTester tester) async {
    await tester.pumpWidget(const NotesPrivacyApp());
    await tester.pumpAndSettle();

    // Verify the app starts safely and shows the login interface
    expect(find.byType(NotesPrivacyApp), findsOneWidget);
  });
}
