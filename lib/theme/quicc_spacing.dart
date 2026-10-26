import 'package:flutter/widgets.dart';

/// Spacing tokens (1.6.0). Use these instead of literal paddings/gaps.
class QuiccSpace {
  QuiccSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// The one padding every pane uses around its content.
  static const double pane = xl;
  static const EdgeInsets paneInsets = EdgeInsets.all(pane);

  static const SizedBox gapXs = SizedBox(width: xs, height: xs);
  static const SizedBox gapSm = SizedBox(width: sm, height: sm);
  static const SizedBox gapMd = SizedBox(width: md, height: md);
  static const SizedBox gapLg = SizedBox(width: lg, height: lg);
  static const SizedBox gapXl = SizedBox(width: xl, height: xl);
}
