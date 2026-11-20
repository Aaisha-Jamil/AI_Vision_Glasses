import 'package:flutter/material.dart';

import 'screens/dashboard_screen.dart';
import 'services/notes_job_service.dart';
import 'theme/app_theme.dart';
import 'widgets/auth_gate.dart';

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
          // background notes generation shows snackbars / dialogs on any screen
          navigatorKey: NotesJobs.navigatorKey,
          scaffoldMessengerKey: NotesJobs.messengerKey,
          builder: (context, child) =>
              NotesProgressBanner(child: child ?? const SizedBox.shrink()),
          debugShowCheckedModeBanner: false,
          title: 'Privacy Preserving Smart Notes',
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
          home: AuthGate(
            themeNotifier: darkMode,
            authenticatedChild: DashboardScreen(
              themeNotifier: darkMode,
              email: 'Authenticated User',
            ),
          ),
        );
      },
    );
  }
}