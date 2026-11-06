import 'package:flutter/material.dart';

/// Tokens that are the **same** in both dark and light modes — the lavender
/// brand ramp (per the brand guidelines: "anchor stays constant across
/// surfaces") and the semantic order-state colors. For theme-swappable
/// tokens (surfaces, text), use [QuiccPalette] via `context.palette.*`.
class QuiccColors {
  // Brand — lavender ramp by default; 2.0.5: the store's accent (Settings →
  // Sound & look → Colors, saved on the Pi) swaps the whole ramp at runtime
  // ([setAccent]), so these are getters, not consts.
  static BrandRamp _ramp = BrandRamp.lavender;
  static BrandRamp get ramp => _ramp;
  static Color get brand50 => _ramp.c50;
  static Color get brand100 => _ramp.c100;
  static Color get brand200 => _ramp.c200;
  static Color get brand400 => _ramp.c400; // anchor
  static Color get brand500 => _ramp.c500;
  static Color get brand600 => _ramp.c600;
  static Color get brand700 => _ramp.c700;
  static Color get brand800 => _ramp.c800;
  static Color get brand900 => _ramp.c900;

  /// Draws the app in [accent] from now on (the lavender ramp for the
  /// default). True when it changed — the caller rebuilds every widget.
  static bool setAccent(Color accent) {
    final next = BrandRamp.from(accent);
    if (next.c400 == _ramp.c400) return false;
    _ramp = next;
    return true;
  }

  // Semantic — order states. Stay the same in both themes; the surrounding
  // surface provides enough contrast in either.
  static const statusOpen = Color(0xFF6BA8FF);
  static const statusPaid = Color(0xFF4ADE80);
  static const statusFiring = Color(0xFFFBBF24);
  static const statusVoided = Color(0xFFF87171);

  // Terminal changes (1.8.0): the blue CHANGED alert and the ticket's glow —
  // apart from the ring's lavender / amber and the red "customer waiting".
  static const changeBlue = Color(0xFF2563EB);
  static const changeBlueDeep = Color(0xFF1E3A8A);
  static const changeBlueSoft = Color(0xFFDBEAFE);

  /// A removed (voided) line: struck through in this red.
  static const removedRed = Color(0xFFDC2626);
}

/// The nine shades the app is drawn in, from one anchor (the 400).
@immutable
class BrandRamp {
  final Color c50, c100, c200, c400, c500, c600, c700, c800, c900;
  const BrandRamp(this.c50, this.c100, this.c200, this.c400, this.c500, this.c600, this.c700, this.c800, this.c900);

  /// The brand guidelines' lavender (exact, so the goldens never move).
  static const lavender = BrandRamp(
    Color(0xFFF4F1FB),
    Color(0xFFE4DFF1),
    Color(0xFFCFC4EE),
    Color(0xFFAC94F4),
    Color(0xFF8A6FE0),
    Color(0xFF6D4FD4),
    Color(0xFF533AA4),
    Color(0xFF3B2974),
    Color(0xFF241B47),
  );

  /// A ramp around [anchor] at the lavender's lightness steps: the light
  /// shades washed out, the deep ones dark enough for text on the anchor.
  factory BrandRamp.from(Color anchor) {
    final a = anchor.withValues(alpha: 1);
    if (a.toARGB32() == lavender.c400.toARGB32()) return lavender;
    final h = HSLColor.fromColor(a);
    Color at(double sat, double light) =>
        h.withSaturation((h.saturation * sat).clamp(0.0, 1.0)).withLightness(light).toColor();
    return BrandRamp(
      at(0.45, 0.96),
      at(0.4, 0.91),
      at(0.6, 0.85),
      a,
      at(0.85, (h.lightness - 0.11).clamp(0.3, 0.7)),
      at(0.75, (h.lightness - 0.2).clamp(0.25, 0.6)),
      at(0.55, 0.43),
      at(0.5, 0.31),
      at(0.45, 0.19),
    );
  }
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
