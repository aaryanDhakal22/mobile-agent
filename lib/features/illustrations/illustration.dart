import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/quicc_colors.dart';

/// The drawings the troubleshooting guides show next to each step: simple,
/// recognisable pictures of the store's hardware, painted in code (no assets)
/// so they follow the light / dark theme.
enum Illustration { raspberryPi, ethernetCable, router, receiptPrinter, sdCard, tablet }

/// The part of a drawing a step points at. Each drawing knows only some parts;
/// the rest are ignored.
enum IllustrationPart {
  none,

  /// Pi: the red power light. Printer: the power light. Router: the lights.
  powerLight,

  /// Pi: the green activity light.
  activityLight,

  /// Pi: the SD-card slot (and the card in it).
  sdSlot,

  /// Pi / router / printer: the network socket.
  networkPort,

  /// Pi / router / printer: where the power cable goes in.
  powerPort,

  /// Cable: the plugs at both ends.
  plugs,

  /// Router: the row of status lights.
  lights,

  /// Printer: the paper roll (lid drawn open, roll direction shown).
  paper,

  /// Printer: the lid.
  lid,

  /// SD card: the card itself.
  card,

  /// Tablet: the Wi-Fi symbol.
  wifi,
}

/// One drawing, optionally with a part highlighted (amber ring) and blinking.
class IllustrationView extends StatefulWidget {
  final Illustration art;
  final IllustrationPart highlight;
  final bool blink;
  final double width;

  const IllustrationView(
    this.art, {
    super.key,
    this.highlight = IllustrationPart.none,
    this.blink = false,
    this.width = 280,
  });

  @override
  State<IllustrationView> createState() => _IllustrationViewState();
}

class _IllustrationViewState extends State<IllustrationView> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(IllustrationView old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final on = widget.blink && widget.highlight != IllustrationPart.none;
    if (on && !_blink.isAnimating) {
      _blink.repeat(reverse: true);
    } else if (!on && _blink.isAnimating) {
      _blink.stop();
      _blink.value = 1;
    } else if (!on) {
      _blink.value = 1;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = IllustrationInk.of(context);
    return Semantics(
      image: true,
      label: _semanticLabel(widget.art),
      child: SizedBox(
        width: widget.width,
        height: widget.width * 0.75,
        child: AnimatedBuilder(
          animation: _blink,
          builder: (_, _) => CustomPaint(
            painter: IllustrationPainter(widget.art, widget.highlight, ink, glow: 0.35 + 0.65 * _blink.value),
          ),
        ),
      ),
    );
  }
}

String _semanticLabel(Illustration a) => switch (a) {
  Illustration.raspberryPi => 'Drawing of the Pi',
  Illustration.ethernetCable => 'Drawing of a network cable',
  Illustration.router => 'Drawing of the router',
  Illustration.receiptPrinter => 'Drawing of a receipt printer',
  Illustration.sdCard => 'Drawing of an SD card',
  Illustration.tablet => 'Drawing of the tablet',
};

/// Theme-aware colours for the drawings.
class IllustrationInk {
  final Color line;
  final Color fill;
  final Color fillAlt;
  final Color muted;
  final Color paper;
  final Color highlight;
  final Color board;
  final Color metal;

  const IllustrationInk({
    required this.line,
    required this.fill,
    required this.fillAlt,
    required this.muted,
    required this.paper,
    required this.highlight,
    required this.board,
    required this.metal,
  });

  static const red = Color(0xFFEF4444);
  static const green = Color(0xFF22C55E);
  static const gold = Color(0xFFD4A537);

  factory IllustrationInk.of(BuildContext context) {
    final p = context.palette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IllustrationInk(
      line: p.textSecondary,
      fill: p.bgElevated,
      fillAlt: p.bgHover,
      muted: p.textMuted,
      paper: dark ? const Color(0xFFF4F1FB) : Colors.white,
      highlight: QuiccColors.statusFiring,
      board: dark ? const Color(0xFF1F6B45) : const Color(0xFF2E8B57),
      metal: dark ? const Color(0xFF9CA3AF) : const Color(0xFFB8BEC8),
    );
  }
}

/// Paints [art] in a 200 × 150 design space scaled to the canvas.
class IllustrationPainter extends CustomPainter {
  final Illustration art;
  final IllustrationPart highlight;
  final IllustrationInk ink;

  /// 0..1 — the highlight ring's strength (animated when blinking).
  final double glow;

  IllustrationPainter(this.art, this.highlight, this.ink, {this.glow = 1});

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width / 200, size.height / 150);
    canvas.save();
    canvas.translate((size.width - 200 * s) / 2, (size.height - 150 * s) / 2);
    canvas.scale(s);
    switch (art) {
      case Illustration.raspberryPi:
        _pi(canvas);
      case Illustration.ethernetCable:
        _cable(canvas);
      case Illustration.router:
        _router(canvas);
      case Illustration.receiptPrinter:
        _printer(canvas);
      case Illustration.sdCard:
        _sdCard(canvas);
      case Illustration.tablet:
        _tablet(canvas);
    }
    canvas.restore();
  }

  // --- helpers ---------------------------------------------------------------

  Paint _fill(Color c) => Paint()..color = c;
  Paint _stroke(Color c, [double w = 2]) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void _box(Canvas c, Rect r, Color fill, {double radius = 6, Color? line, double w = 2}) {
    final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
    c.drawRRect(rr, _fill(fill));
    c.drawRRect(rr, _stroke(line ?? ink.line, w));
  }

  void _led(Canvas c, Offset at, Color color, {double r = 4}) {
    c.drawCircle(at, r + 3, _fill(color.withValues(alpha: 0.25)));
    c.drawCircle(at, r, _fill(color));
  }

  /// The amber ring around the highlighted part.
  void _ring(Canvas c, Rect r, {bool circle = false}) {
    final a = glow.clamp(0.0, 1.0);
    final glowPaint = _fill(ink.highlight.withValues(alpha: 0.18 * a));
    final line = _stroke(ink.highlight.withValues(alpha: a), 3);
    if (circle) {
      c.drawCircle(r.center, r.shortestSide / 2, glowPaint);
      c.drawCircle(r.center, r.shortestSide / 2, line);
    } else {
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(8));
      c.drawRRect(rr, glowPaint);
      c.drawRRect(rr, line);
    }
  }

  void _arrow(Canvas c, Offset from, Offset to, Color color, {double w = 3}) {
    c.drawLine(from, to, _stroke(color, w));
    final ang = math.atan2(to.dy - from.dy, to.dx - from.dx);
    const head = 8.0;
    final p = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(to.dx - head * math.cos(ang - 0.5), to.dy - head * math.sin(ang - 0.5))
      ..moveTo(to.dx, to.dy)
      ..lineTo(to.dx - head * math.cos(ang + 0.5), to.dy - head * math.sin(ang + 0.5));
    c.drawPath(p, _stroke(color, w));
  }

  bool _is(IllustrationPart p) => highlight == p;

  // --- Raspberry Pi -----------------------------------------------------------

  void _pi(Canvas c) {
    // SD card sticking out of the left edge (drawn under the board).
    final sd = const Rect.fromLTWH(6, 62, 20, 22);
    _box(c, sd, ink.fillAlt, radius: 2, w: 1.5);
    c.drawLine(const Offset(10, 66), const Offset(10, 80), _stroke(IllustrationInk.gold, 1.5));

    // Board.
    _box(c, const Rect.fromLTWH(18, 25, 164, 104), ink.board, radius: 8);
    for (final h in const [Offset(26, 33), Offset(174, 33), Offset(26, 121), Offset(174, 121)]) {
      c.drawCircle(h, 3.5, _fill(ink.fill));
      c.drawCircle(h, 3.5, _stroke(ink.line, 1));
    }
    // GPIO header.
    for (var i = 0; i < 18; i++) {
      c.drawRect(Rect.fromLTWH(40 + i * 6.0, 29, 4, 4), _fill(IllustrationInk.gold));
      c.drawRect(Rect.fromLTWH(40 + i * 6.0, 35, 4, 4), _fill(IllustrationInk.gold));
    }
    // Chip.
    _box(c, const Rect.fromLTWH(60, 58, 36, 36), ink.metal, radius: 3, w: 1.5);
    // USB ports + network socket on the right edge.
    _box(c, const Rect.fromLTWH(152, 46, 36, 20), ink.metal, radius: 2, w: 1.5);
    _box(c, const Rect.fromLTWH(152, 70, 36, 20), ink.metal, radius: 2, w: 1.5);
    final eth = const Rect.fromLTWH(148, 96, 40, 26);
    _box(c, eth, ink.metal, radius: 2, w: 1.5);
    _box(c, const Rect.fromLTWH(160, 102, 16, 14), ink.fill, radius: 1, w: 1.5);
    // Power socket (USB-C) on the bottom edge.
    final pwr = const Rect.fromLTWH(34, 122, 18, 9);
    _box(c, pwr, ink.metal, radius: 4, w: 1.5);
    // LEDs: red power, green activity.
    const redAt = Offset(32, 92), greenAt = Offset(32, 106);
    _led(c, redAt, IllustrationInk.red);
    _led(c, greenAt, IllustrationInk.green);

    if (_is(IllustrationPart.powerLight)) _ring(c, Rect.fromCircle(center: redAt, radius: 11), circle: true);
    if (_is(IllustrationPart.activityLight)) _ring(c, Rect.fromCircle(center: greenAt, radius: 11), circle: true);
    if (_is(IllustrationPart.sdSlot)) _ring(c, sd.inflate(5));
    if (_is(IllustrationPart.networkPort)) _ring(c, eth.inflate(5));
    if (_is(IllustrationPart.powerPort)) _ring(c, pwr.inflate(6));
  }

  // --- Network cable ------------------------------------------------------------

  void _cable(Canvas c) {
    // Socket on the left (the Pi / router side).
    _box(c, const Rect.fromLTWH(10, 45, 44, 60), ink.fill, radius: 6);
    _box(c, const Rect.fromLTWH(22, 62, 22, 26), ink.fillAlt, radius: 2, w: 1.5);
    // Plug, pulled a little out of it.
    final plugL = const Rect.fromLTWH(62, 62, 34, 26);
    _box(c, plugL, ink.paper.withValues(alpha: 0.85), radius: 3, w: 1.5);
    c.drawLine(const Offset(70, 62), const Offset(80, 54), _stroke(ink.line, 2)); // clip
    for (var i = 0; i < 4; i++) {
      c.drawLine(Offset(65, 67 + i * 5.0), Offset(71, 67 + i * 5.0), _stroke(IllustrationInk.gold, 1.5));
    }
    // Cable to the right-hand plug.
    final cable = Path()
      ..moveTo(96, 75)
      ..cubicTo(130, 75, 120, 120, 150, 115)
      ..cubicTo(170, 112, 170, 90, 172, 82);
    c.drawPath(cable, _stroke(QuiccColors.statusOpen, 6));
    final plugR = const Rect.fromLTWH(160, 56, 24, 26);
    _box(c, plugR, ink.paper.withValues(alpha: 0.85), radius: 3, w: 1.5);
    // Push-in / pull-out arrow over the left plug.
    _arrow(c, const Offset(100, 36), const Offset(62, 36), ink.highlight);
    _arrow(c, const Offset(62, 36), const Offset(100, 36), ink.highlight);

    if (_is(IllustrationPart.plugs) || _is(IllustrationPart.networkPort)) {
      _ring(c, plugL.inflate(6));
      _ring(c, plugR.inflate(6));
    }
  }

  // --- Router / switch ------------------------------------------------------------

  void _router(Canvas c) {
    // Antennas.
    c.drawLine(const Offset(50, 72), const Offset(40, 22), _stroke(ink.line, 4));
    c.drawLine(const Offset(150, 72), const Offset(160, 22), _stroke(ink.line, 4));
    // Body.
    _box(c, const Rect.fromLTWH(22, 70, 156, 50), ink.fill, radius: 10);
    // Status lights.
    final lights = <Offset>[for (var i = 0; i < 5; i++) Offset(48 + i * 18.0, 95)];
    for (var i = 0; i < lights.length; i++) {
      _led(
        c,
        lights[i],
        i == 0 ? IllustrationInk.green : (i.isEven ? IllustrationInk.green : QuiccColors.statusOpen),
        r: 3.5,
      );
    }
    // Network sockets on the right.
    final ports = const Rect.fromLTWH(134, 86, 36, 18);
    for (var i = 0; i < 2; i++) {
      _box(c, Rect.fromLTWH(136 + i * 17.0, 88, 14, 14), ink.fillAlt, radius: 1, w: 1.5);
    }
    // Power cable from the back.
    c.drawLine(const Offset(178, 112), const Offset(196, 136), _stroke(ink.muted, 3));
    final pwr = const Rect.fromLTWH(170, 106, 12, 12);

    if (_is(IllustrationPart.lights) || _is(IllustrationPart.powerLight)) {
      _ring(c, Rect.fromLTRB(lights.first.dx - 10, 84, lights.last.dx + 10, 106));
    }
    if (_is(IllustrationPart.networkPort) || _is(IllustrationPart.plugs)) _ring(c, ports.inflate(4));
    if (_is(IllustrationPart.powerPort)) _ring(c, pwr.inflate(6), circle: true);
  }

  // --- Receipt printer ---------------------------------------------------------------

  void _printer(Canvas c) {
    final open = _is(IllustrationPart.paper);
    // Body.
    _box(c, const Rect.fromLTWH(36, 62, 128, 66), ink.fill, radius: 10);
    // Paper roll inside (visible when the lid is drawn open).
    const rollAt = Offset(100, 62);
    if (open) {
      c.drawCircle(rollAt, 22, _fill(ink.paper));
      c.drawCircle(rollAt, 22, _stroke(ink.line, 1.5));
      c.drawCircle(rollAt, 6, _stroke(ink.muted, 1.5));
      // Paper leaves the BOTTOM of the roll and comes out toward the front.
      final feed = Path()
        ..moveTo(100, 84)
        ..lineTo(150, 84)
        ..lineTo(150, 30);
      c.drawPath(feed, _stroke(ink.paper, 5));
      _arrow(c, const Offset(112, 90), const Offset(142, 90), ink.highlight);
      // The lid, flipped up behind.
      _box(c, const Rect.fromLTWH(40, 18, 70, 18), ink.fillAlt, radius: 6);
    } else {
      // Closed lid with the slip coming out of the slot.
      final lid = const Rect.fromLTWH(36, 40, 128, 30);
      _box(c, lid, ink.fillAlt, radius: 10);
      final slip = Path()
        ..moveTo(82, 44)
        ..lineTo(82, 14)
        ..lineTo(118, 14)
        ..lineTo(118, 44);
      c.drawPath(slip, _fill(ink.paper));
      c.drawPath(slip, _stroke(ink.line, 1.5));
      for (var i = 0; i < 3; i++) {
        c.drawLine(Offset(88, 22 + i * 7.0), Offset(112 - i * 6.0, 22 + i * 7.0), _stroke(ink.muted, 1.5));
      }
      c.drawLine(const Offset(70, 44), const Offset(130, 44), _stroke(ink.line, 2)); // slot
      if (_is(IllustrationPart.lid)) _ring(c, lid.inflate(4));
    }
    // Power light + button on the front.
    const lightAt = Offset(146, 112);
    _led(c, lightAt, IllustrationInk.green, r: 3.5);
    _box(c, const Rect.fromLTWH(118, 106, 16, 12), ink.fillAlt, radius: 3, w: 1.5);
    // Cables at the back.
    c.drawLine(const Offset(40, 120), const Offset(14, 140), _stroke(QuiccColors.statusOpen, 4));
    c.drawLine(const Offset(48, 124), const Offset(30, 146), _stroke(ink.muted, 3));

    if (_is(IllustrationPart.powerLight)) _ring(c, Rect.fromCircle(center: lightAt, radius: 11), circle: true);
    if (_is(IllustrationPart.paper)) _ring(c, Rect.fromCircle(center: rollAt, radius: 30), circle: true);
    if (_is(IllustrationPart.networkPort) || _is(IllustrationPart.plugs)) {
      _ring(c, const Rect.fromLTWH(8, 112, 40, 36));
    }
    if (_is(IllustrationPart.powerPort)) _ring(c, const Rect.fromLTWH(24, 124, 30, 26));
  }

  // --- SD card -----------------------------------------------------------------------

  void _sdCard(Canvas c) {
    // A microSD card: notch on the right side.
    final card = Path()
      ..moveTo(70, 30)
      ..lineTo(126, 30)
      ..lineTo(126, 60)
      ..lineTo(120, 66)
      ..lineTo(126, 72)
      ..lineTo(126, 120)
      ..lineTo(70, 120)
      ..close();
    c.drawPath(card, _fill(ink.fillAlt));
    c.drawPath(card, _stroke(ink.line, 2));
    for (var i = 0; i < 7; i++) {
      c.drawRect(Rect.fromLTWH(74 + i * 7.0, 34, 4, 14), _fill(IllustrationInk.gold));
    }
    // Label.
    c.drawRect(const Rect.fromLTWH(78, 78, 40, 30), _fill(QuiccColors.brand400.withValues(alpha: 0.6)));
    // Gold end goes in first.
    _arrow(c, const Offset(98, 26), const Offset(98, 4), ink.highlight);
    if (_is(IllustrationPart.card) || _is(IllustrationPart.sdSlot)) _ring(c, const Rect.fromLTWH(62, 22, 72, 106));
  }

  // --- Tablet ------------------------------------------------------------------------

  void _tablet(Canvas c) {
    _box(c, const Rect.fromLTWH(22, 20, 156, 110), ink.fillAlt, radius: 14);
    _box(c, const Rect.fromLTWH(32, 30, 136, 90), ink.fill, radius: 4, w: 1.5);
    // Wi-Fi symbol.
    const at = Offset(100, 95);
    final wifi = _stroke(QuiccColors.brand400, 6);
    for (final r in const [16.0, 30.0, 44.0]) {
      c.drawArc(Rect.fromCircle(center: at, radius: r), -math.pi * 0.75, math.pi * 0.5, false, wifi);
    }
    c.drawCircle(at, 5, _fill(QuiccColors.brand400));
    if (_is(IllustrationPart.wifi)) _ring(c, const Rect.fromLTWH(48, 40, 104, 66));
  }

  @override
  bool shouldRepaint(IllustrationPainter old) =>
      old.art != art || old.highlight != highlight || old.glow != glow || old.ink.line != ink.line;
}
