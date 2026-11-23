import 'package:flutter/material.dart';

class AppTheme {
  // ---------------------------------------------------------------------------
  // Core 5-colour palette (from the design image)
  // ---------------------------------------------------------------------------
  static const Color slateGreen = Color(0xFF5A8A7A); // #5A8A7A (Muted Sage Green)
  static const Color softSage = Color(0xFF8FB7A9); // #8FB7A9 (Soft Sage / Light Seafoam)
  static const Color warmCream = Color(0xFFF3E7D3); // #F3E7D3 (Warm Cream Parchment)
  static const Color warmSand = Color(0xFFD6C3A3); // #D6C3A3 (Warm Sand / Almond Tan)
  static const Color deepForest = Color(0xFF2E5E55); // #2E5E55 (Deep Forest Slate / Pine Teal)
  static const Color accentTeal = Color(0xFF3B8A7E); // #3B8A7E (AI Vision Glasses Accent)

  // Backwards-compatible semantic aliases
  static const Color seaBlue = deepForest;
  static const Color seaGreen = slateGreen;
  static const Color paleSea = Color(0xFFFAF6EE);
  static const Color deepOcean = Color(0xFF1B3833);

  // ---------------------------------------------------------------------------
  // Neutral / surface helpers (palette-tinted, replace Colors.grey / black87 ...)
  // ---------------------------------------------------------------------------
  static const Color ink = Color(0xFF182622); // main text on light
  static const Color mutedText = Color(0xFF7C8A85); // replaces Colors.grey / grey.shade600
  static const Color mutedTextLight = Color(0xFF9CA8A3); // replaces Colors.grey.shade400
  static const Color surfaceDark = Color(0xFF1A332D); // dark cards / panels
  static const Color boardDark = Color(0xFF14302B); // board preview background (dark)

  // ---------------------------------------------------------------------------
  // Status colours - earthy tones that sit well with the sage/cream palette
  // ---------------------------------------------------------------------------
  static const Color success = Color(0xFF4A9B76); // replaces Colors.green
  static const Color warning = Color(0xFFC8923A); // replaces Colors.orange / amber (ochre)
  static const Color info = slateGreen; // replaces Colors.blue
  static const Color danger = Color(0xFFC0503F); // replaces Colors.red (terracotta)
  static const Color dangerDark = Color(0xFF9E3B2D); // replaces Colors.red.shade700
  static const Color dangerDeep = Color(0xFF7A2B20); // replaces Colors.red.shade800
  static const Color dangerSoft = Color(0xFFE3897A); // replaces Colors.red.shade300
  static const Color dangerLight = Color(0xFFEFB4A9); // replaces Colors.red.shade200
  static const Color dangerSurfaceLight = Color(0xFFFBE9E4); // flagged card bg (light)
  static const Color dangerSurfaceDark = Color(0xFF3A2320); // flagged card bg (dark)

  /// Helper to get the primary accent based on dark/light mode
  static Color primary(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? softSage : deepForest;
  }

  /// Helper to get secondary accent
  static Color secondary(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? warmSand : slateGreen;
  }

  // ---------------------------------------------------------------------------
  // LIGHT THEME
  // ---------------------------------------------------------------------------
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme(
        brightness: Brightness.light,
        primary: deepForest,
        onPrimary: Colors.white,
        primaryContainer: softSage,
        onPrimaryContainer: Color(0xFF0F2620),
        secondary: slateGreen,
        onSecondary: Colors.white,
        secondaryContainer: warmCream,
        onSecondaryContainer: Color(0xFF243630),
        tertiary: warmSand,
        onTertiary: Color(0xFF2B2110),
        tertiaryContainer: Color(0xFFFAF3E7),
        onTertiaryContainer: Color(0xFF2B2110),
        error: danger,
        onError: Colors.white,
        errorContainer: dangerSurfaceLight,
        onErrorContainer: Color(0xFF410002),
        surface: Colors.white,
        onSurface: ink,
        surfaceContainerHighest: warmCream,
        outline: warmSand,
        outlineVariant: Color(0xFFE5DAC9),
      ),
      scaffoldBackgroundColor: paleSea,
      appBarTheme: const AppBarTheme(
        backgroundColor: deepForest,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: Colors.white),
        actionsIconTheme: IconThemeData(color: Colors.white),
        centerTitle: false,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 1.5,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFFE5DAC8), width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: deepForest,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 1.5,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: deepForest,
          side: const BorderSide(color: slateGreen, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: deepForest,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: deepForest,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: deepForest,
        foregroundColor: Colors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        prefixIconColor: slateGreen,
        suffixIconColor: slateGreen,
        labelStyle: const TextStyle(color: mutedText),
        floatingLabelStyle: const TextStyle(color: deepForest),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: warmSand),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFDCCDB5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: deepForest, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: danger, width: 2),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: warmCream,
        selectedColor: softSage,
        side: const BorderSide(color: warmSand),
        labelStyle: const TextStyle(color: deepForest, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected) ? deepForest : null,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected) ? softSage : null,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected) ? deepForest : null,
        ),
        checkColor: const WidgetStatePropertyAll<Color>(Colors.white),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected) ? deepForest : null,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: paleSea,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titleTextStyle: const TextStyle(
          color: deepForest,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        contentTextStyle: const TextStyle(color: ink, fontSize: 14),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: deepForest,
        contentTextStyle: const TextStyle(color: warmCream),
        actionTextColor: warmSand,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: paleSea,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: deepForest,
        linearTrackColor: warmCream,
        circularTrackColor: warmCream,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE5DAC9),
        thickness: 1,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: deepForest,
        textColor: ink,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: deepForest,
        selectionColor: Color(0x558FB7A9),
        selectionHandleColor: deepForest,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DARK THEME
  // ---------------------------------------------------------------------------
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme(
        brightness: Brightness.dark,
        primary: softSage,
        onPrimary: Color(0xFF0C241E),
        primaryContainer: deepForest,
        onPrimaryContainer: warmCream,
        secondary: slateGreen,
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFF264840),
        onSecondaryContainer: warmCream,
        tertiary: warmSand,
        onTertiary: Color(0xFF2B2110),
        tertiaryContainer: Color(0xFF3F3423),
        onTertiaryContainer: warmCream,
        error: dangerSoft,
        onError: Color(0xFF690005),
        errorContainer: dangerSurfaceDark,
        onErrorContainer: Color(0xFFFFDAD6),
        surface: Color(0xFF1F3832),
        onSurface: warmCream,
        surfaceContainerHighest: deepForest,
        outline: slateGreen,
        outlineVariant: Color(0xFF3B5750),
      ),
      scaffoldBackgroundColor: const Color(0xFF132521),
      appBarTheme: const AppBarTheme(
        backgroundColor: surfaceDark,
        foregroundColor: warmCream,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: warmCream),
        actionsIconTheme: IconThemeData(color: warmCream),
        centerTitle: false,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1F3832),
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF2F4F47), width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: deepForest,
          foregroundColor: warmCream,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 2,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: softSage,
          side: const BorderSide(color: softSage, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: deepForest,
          foregroundColor: warmCream,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: softSage,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: slateGreen,
        foregroundColor: Colors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF19302B),
        prefixIconColor: softSage,
        suffixIconColor: softSage,
        labelStyle: const TextStyle(color: mutedTextLight),
        floatingLabelStyle: const TextStyle(color: softSage),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: slateGreen),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF38574F)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: softSage, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: dangerSoft),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: dangerSoft, width: 2),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: deepForest,
        selectedColor: slateGreen,
        side: const BorderSide(color: slateGreen),
        labelStyle: const TextStyle(color: warmCream, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected) ? softSage : null,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected) ? deepForest : null,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected) ? softSage : null,
        ),
        checkColor: const WidgetStatePropertyAll<Color>(Color(0xFF0C241E)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected) ? softSage : null,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF1F3832),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titleTextStyle: const TextStyle(
          color: warmCream,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        contentTextStyle: const TextStyle(color: warmCream, fontSize: 14),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: warmCream,
        contentTextStyle: const TextStyle(color: deepForest),
        actionTextColor: slateGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF1F3832),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: softSage,
        linearTrackColor: Color(0xFF264840),
        circularTrackColor: Color(0xFF264840),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF3B5750),
        thickness: 1,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: softSage,
        textColor: warmCream,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: softSage,
        selectionColor: Color(0x558FB7A9),
        selectionHandleColor: softSage,
      ),
    );
  }
}
