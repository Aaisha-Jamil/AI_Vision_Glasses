import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';

class NotesPrivacyApp extends StatefulWidget {
  const NotesPrivacyApp({super.key});

  @override
  State<NotesPrivacyApp> createState() => _NotesPrivacyAppState();
}

class _NotesPrivacyAppState extends State<NotesPrivacyApp> {
  final ValueNotifier<bool> darkMode = ValueNotifier<bool>(false);

  @override
  void dispose() {
    darkMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: darkMode,
      builder: (context, isDark, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Privacy Preserving Smart Notes',
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
          home: LoginScreen(themeNotifier: darkMode),
        );
      },
    );
  }
}
