import 'package:flutter/material.dart';

import 'quicc_colors.dart';
import 'quicc_type.dart';

class QuiccTheme {
  static ThemeData dark() => _build(Brightness.dark, QuiccPalette.dark);
  static ThemeData light() => _build(Brightness.light, QuiccPalette.light);

  static ThemeData _build(Brightness brightness, QuiccPalette palette) {
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final textTheme = QuiccType.textTheme(palette.textPrimary);

    final onPrimary = brightness == Brightness.dark
        ? QuiccColors.brand900
        : QuiccColors.brand50;

    return base.copyWith(
      scaffoldBackgroundColor: palette.bgCanvas,
      colorScheme: ColorScheme.fromSeed(
        seedColor: QuiccColors.brand400,
        brightness: brightness,
        primary: QuiccColors.brand400,
        onPrimary: onPrimary,
        surface: palette.bgSurface,
        onSurface: palette.textPrimary,
        error: QuiccColors.statusVoided,
      ),
      extensions: [palette],
      textTheme: textTheme,
      dividerColor: palette.borderSoft,
      cardTheme: CardThemeData(
        color: palette.bgSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.lg),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: QuiccColors.brand400,
          foregroundColor: onPrimary,
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
          side: BorderSide(color: palette.borderSoft, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(QuiccRadius.cta),
          ),
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.bgElevated,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.md),
          borderSide: BorderSide(color: palette.borderSoft),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.md),
          borderSide: BorderSide(color: palette.borderSoft),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(QuiccRadius.md),
          borderSide: const BorderSide(color: QuiccColors.brand400, width: 2),
        ),
      ),
    );
  }
}
