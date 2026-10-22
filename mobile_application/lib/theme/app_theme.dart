import 'package:flutter/material.dart';

class AppTheme {
  static const Color seaBlue = Color(0xFF087EAA);
  static const Color seaGreen = Color(0xFF159A8C);
  static const Color paleSea = Color(0xFFEAF7F6);
  static const Color deepOcean = Color(0xFF092E3D);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seaBlue,
        brightness: Brightness.light,
        primary: seaBlue,
        secondary: seaGreen,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: paleSea,
      appBarTheme: const AppBarTheme(
        backgroundColor: seaBlue,
        foregroundColor: Colors.white,
        centerTitle: false,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: seaBlue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 14,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected)
              ? seaGreen
              : null,
        ),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seaGreen,
        brightness: Brightness.dark,
        primary: const Color(0xFF56C7E8),
        secondary: const Color(0xFF55D6BE),
        surface: const Color(0xFF103A48),
      ),
      scaffoldBackgroundColor: const Color(0xFF071F2A),
      appBarTheme: const AppBarTheme(
        backgroundColor: deepOcean,
        foregroundColor: Colors.white,
        centerTitle: false,
      ),
      cardTheme: const CardThemeData(
        color: Color(0xFF103A48),
        elevation: 2,
        margin: EdgeInsets.symmetric(vertical: 6),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: seaGreen,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 14,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF164452),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected)
              ? const Color(0xFF55D6BE)
              : null,
        ),
      ),
    );
  }
}
