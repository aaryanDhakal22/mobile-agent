import 'package:flutter/material.dart';

/// The type scale (1.6.0). Six sizes, two families: Inter for words, JetBrains
/// Mono for numbers that must line up or be read from across the kitchen
/// (kitchen #, timers, money, times). Use these instead of inline font sizes.
///
///   display 40 — the kitchen # on a ticket, the big timer
///   title   28 — pane titles, the alert's customer line
///   heading 20 — card titles, driver names, primary buttons
///   body    16 — items, rows, most text
///   label   14 — secondary buttons, tags, field labels
///   caption 12 — hints, explanations under settings, timestamps
class QuiccType {
  QuiccType._();

  static const sans = 'Inter';
  static const mono = 'JetBrainsMono';

  static const double display = 40;
  static const double title = 28;
  static const double heading = 20;
  static const double body = 16;
  static const double label = 14;
  static const double caption = 12;

  /// Text in Inter at a scale size.
  static TextStyle text(double size, {FontWeight weight = FontWeight.w400, Color? color, double? height}) =>
      TextStyle(fontFamily: sans, fontSize: size, fontWeight: weight, color: color, height: height);

  /// Numbers in JetBrains Mono at a scale size (tabular by design).
  static TextStyle number(double size, {FontWeight weight = FontWeight.w600, Color? color, double? height}) =>
      TextStyle(fontFamily: mono, fontSize: size, fontWeight: weight, color: color, height: height);

  /// The Material text theme mapped onto the scale (Inter throughout).
  static TextTheme textTheme(Color color) {
    TextStyle s(double size, FontWeight w) => text(size, weight: w, color: color);
    return TextTheme(
      displayLarge: s(display, FontWeight.w700),
      displayMedium: s(display, FontWeight.w600),
      displaySmall: s(title, FontWeight.w700),
      headlineLarge: s(title, FontWeight.w700),
      headlineMedium: s(title, FontWeight.w600),
      headlineSmall: s(heading, FontWeight.w700),
      titleLarge: s(heading, FontWeight.w600),
      titleMedium: s(body, FontWeight.w600),
      titleSmall: s(label, FontWeight.w600),
      bodyLarge: s(body, FontWeight.w400),
      bodyMedium: s(body, FontWeight.w400),
      bodySmall: s(label, FontWeight.w400),
      labelLarge: s(label, FontWeight.w600),
      labelMedium: s(caption, FontWeight.w600),
      labelSmall: s(caption, FontWeight.w500),
    );
  }
}
