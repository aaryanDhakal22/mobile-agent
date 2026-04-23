import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'quicc_colors.dart';

class QuiccTheme {
  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = GoogleFonts.jetBrainsMonoTextTheme(base.textTheme).apply(
      bodyColor: QuiccColors.textPrimary,
      displayColor: QuiccColors.textPrimary,
    );

    return base.copyWith(
      scaffoldBackgroundColor: QuiccColors.bgCanvas,
      colorScheme: ColorScheme.fromSeed(
        seedColor: QuiccColors.brand400,
        brightness: Brightness.dark,
        primary: QuiccColors.brand400,
        onPrimary: QuiccColors.brand900,
        surface: QuiccColors.bgSurface,
        onSurface: QuiccColors.textPrimary,
        error: QuiccColors.statusVoided,
      ),
      textTheme: textTheme,
      dividerColor: QuiccColors.borderSoft,
      cardTheme: CardThemeData(
        color: QuiccColors.bgSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.lg),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: QuiccColors.brand400,
          foregroundColor: QuiccColors.brand900,
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(QuiccRadius.cta),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: QuiccColors.brand400,
          side: const BorderSide(color: QuiccColors.borderSoft, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(QuiccRadius.cta),
          ),
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: QuiccColors.bgSurface,
        indicatorColor: QuiccColors.brand400.withValues(alpha: 0.18),
        selectedIconTheme: const IconThemeData(color: QuiccColors.brand400),
        unselectedIconTheme: const IconThemeData(color: QuiccColors.textMuted),
        selectedLabelTextStyle: textTheme.labelLarge?.copyWith(color: QuiccColors.brand400),
        unselectedLabelTextStyle: textTheme.labelLarge?.copyWith(color: QuiccColors.textMuted),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: QuiccColors.bgElevated,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.md),
          borderSide: const BorderSide(color: QuiccColors.borderSoft),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.md),
          borderSide: const BorderSide(color: QuiccColors.borderSoft),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.md),
          borderSide: const BorderSide(color: QuiccColors.brand400, width: 2),
        ),
      ),
    );
  }
}
