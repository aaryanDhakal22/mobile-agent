import 'package:flutter/material.dart';

/// Tokens that are the **same** in both dark and light modes — the lavender
/// brand ramp (per the brand guidelines: "anchor stays constant across
/// surfaces") and the semantic order-state colors. For theme-swappable
/// tokens (surfaces, text), use [QuiccPalette] via `context.palette.*`.
class QuiccColors {
  // Brand — lavender ramp
  static const brand50 = Color(0xFFF4F1FB);
  static const brand100 = Color(0xFFE4DFF1);
  static const brand200 = Color(0xFFCFC4EE);
  static const brand400 = Color(0xFFAC94F4); // anchor
  static const brand500 = Color(0xFF8A6FE0);
  static const brand600 = Color(0xFF6D4FD4);
  static const brand700 = Color(0xFF533AA4);
  static const brand800 = Color(0xFF3B2974);
  static const brand900 = Color(0xFF241B47);

  // Semantic — order states. Stay the same in both themes; the surrounding
  // surface provides enough contrast in either.
  static const statusOpen = Color(0xFF6BA8FF);
  static const statusPaid = Color(0xFF4ADE80);
  static const statusFiring = Color(0xFFFBBF24);
  static const statusVoided = Color(0xFFF87171);
}

class QuiccRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 14;
  static const double xl = 20;
  static const double tile = 14;
  static const double cta = 12;
}

/// Theme-swappable surface + text tokens. Registered on `ThemeData` via
/// `extensions:` so `context.palette.*` resolves to the right values for
/// whichever mode MaterialApp is showing. Keep these in the same order
/// and shape as the brand spec so the two modes remain structurally
/// interchangeable.
@immutable
class QuiccPalette extends ThemeExtension<QuiccPalette> {
  final Color bgCanvas;
  final Color bgSurface;
  final Color bgElevated;
  final Color bgHover;
  final Color borderSoft;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  const QuiccPalette({
    required this.bgCanvas,
    required this.bgSurface,
    required this.bgElevated,
    required this.bgHover,
    required this.borderSoft,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
  });

  static const dark = QuiccPalette(
    bgCanvas: Color(0xFF0F0D1A),
    bgSurface: Color(0xFF171425),
    bgElevated: Color(0xFF211D35),
    bgHover: Color(0xFF2D2844),
    borderSoft: Color(0xFF2A2640),
    textPrimary: Color(0xFFF4F1FB),
    textSecondary: Color(0xFFB8B0D4),
    textMuted: Color(0xFF8A82A8),
  );

  /// Light-surface variant shown on page 3 of the brand PDF: white tile,
  /// deep lavender text. Tuned so the lavender anchor (`brand400`) still
  /// reads as the primary accent against a near-white canvas.
  static const light = QuiccPalette(
    bgCanvas: Color(0xFFFAFAFF),
    bgSurface: Color(0xFFFFFFFF),
    bgElevated: Color(0xFFF4F1FB),
    bgHover: Color(0xFFE4DFF1),
    borderSoft: Color(0xFFCFC4EE),
    textPrimary: Color(0xFF1A1530),
    textSecondary: Color(0xFF533AA4),
    textMuted: Color(0xFF6D4FD4),
  );

  @override
  QuiccPalette copyWith({
    Color? bgCanvas,
    Color? bgSurface,
    Color? bgElevated,
    Color? bgHover,
    Color? borderSoft,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
  }) {
    return QuiccPalette(
      bgCanvas: bgCanvas ?? this.bgCanvas,
      bgSurface: bgSurface ?? this.bgSurface,
      bgElevated: bgElevated ?? this.bgElevated,
      bgHover: bgHover ?? this.bgHover,
      borderSoft: borderSoft ?? this.borderSoft,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
    );
  }

  @override
  QuiccPalette lerp(ThemeExtension<QuiccPalette>? other, double t) {
    if (other is! QuiccPalette) return this;
    return QuiccPalette(
      bgCanvas: Color.lerp(bgCanvas, other.bgCanvas, t)!,
      bgSurface: Color.lerp(bgSurface, other.bgSurface, t)!,
      bgElevated: Color.lerp(bgElevated, other.bgElevated, t)!,
      bgHover: Color.lerp(bgHover, other.bgHover, t)!,
      borderSoft: Color.lerp(borderSoft, other.borderSoft, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
    );
  }
}

extension QuiccPaletteContext on BuildContext {
  /// Returns the active theme's palette. Falls back to dark if the theme
  /// hasn't registered the extension (shouldn't happen in production).
  QuiccPalette get palette =>
      Theme.of(this).extension<QuiccPalette>() ?? QuiccPalette.dark;
}
