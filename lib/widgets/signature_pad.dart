import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Logical size the signature is exported at. The on-screen pad uses the same
/// aspect ratio so the box the requester draws in is a faithful preview of the
/// image printed on the official permit.
const Size kSignatureCanvasSize = Size(600, 230);
const Color kSignatureInk = Color(0xFF12161C);
const Color kSignatureSurface = Color(0xFFFFFFFF);

/// Paints strokes held in normalized 0..1 space. Shared by the on-screen
/// painter and the PNG exporter so what the requester sees is exactly what is
/// submitted.
void paintSignature(
  Canvas canvas,
  Size size,
  List<List<Offset>> strokes, {
  required double strokeWidth,
  Color ink = kSignatureInk,
}) {
  final paint = Paint()
    ..color = ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  for (final stroke in strokes) {
    if (stroke.isEmpty) continue;
    final points = [
      for (final point in stroke)
        Offset(point.dx * size.width, point.dy * size.height),
    ];
    if (points.length == 1) {
      canvas.drawCircle(
        points.first,
        strokeWidth / 2,
        Paint()
          ..color = ink
          ..isAntiAlias = true,
      );
      continue;
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final mid = Offset(
        (points[i].dx + points[i + 1].dx) / 2,
        (points[i].dy + points[i + 1].dy) / 2,
      );
      path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    canvas.drawPath(path, paint);
  }
}

/// Renders strokes to an opaque white PNG.
///
/// Opaque white rather than transparent so the result matches what scanned or
/// photographed signature uploads looked like before, and nothing downstream
/// has to start handling an alpha channel. Pure, so it is directly testable.
Future<Uint8List> renderSignaturePng(
  List<List<Offset>> strokes, {
  Size logicalSize = kSignatureCanvasSize,
  double pixelRatio = 3,
}) async {
  final width = (logicalSize.width * pixelRatio).round();
  final height = (logicalSize.height * pixelRatio).round();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = kSignatureSurface,
  );
  paintSignature(
    canvas,
    Size(width.toDouble(), height.toDouble()),
    strokes,
    strokeWidth: 3.0 * pixelRatio,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('Signature could not be rendered.');
    }
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// Holds the strokes drawn on a [SignaturePad] in normalized 0..1 coordinates
/// relative to the painted box, so a signature drawn on a phone and one drawn
/// on a desktop export to the same image.
class SignaturePadController extends ChangeNotifier {
  final List<List<Offset>> _strokes = [];

  List<List<Offset>> get strokes => [
    for (final stroke in _strokes) List<Offset>.unmodifiable(stroke),
  ];

  bool get isEmpty => _strokes.isEmpty;

  /// Total normalized path length across every stroke.
  double get inkLength {
    var total = 0.0;
    for (final stroke in _strokes) {
      for (var i = 1; i < stroke.length; i++) {
        total += (stroke[i] - stroke[i - 1]).distance;
      }
    }
    return total;
  }

  /// Guards a stray tap from being submitted as a signature, so the requester
  /// sees an inline error instead of the server's blank-signature rejection.
  bool get hasEnoughInk => inkLength >= 0.35;

  void beginStroke(Offset point) {
    _strokes.add([_clamp(point)]);
    notifyListeners();
  }

  void extendStroke(Offset point) {
    if (_strokes.isEmpty) return;
    final stroke = _strokes.last;
    final next = _clamp(point);
    // Drop sub-pixel jitter so a long signature stays cheap to repaint.
    if (stroke.isNotEmpty && (next - stroke.last).distance < 0.002) return;
    stroke.add(next);
    notifyListeners();
  }

  void endStroke() {
    if (_strokes.isNotEmpty && _strokes.last.isEmpty) {
      _strokes.removeLast();
    }
    notifyListeners();
  }

  void undo() {
    if (_strokes.isEmpty) return;
    _strokes.removeLast();
    notifyListeners();
  }

  void clear() {
    if (_strokes.isEmpty) return;
    _strokes.clear();
    notifyListeners();
  }

  static Offset _clamp(Offset point) =>
      Offset(point.dx.clamp(0.0, 1.0), point.dy.clamp(0.0, 1.0));
}

/// A drawing surface for a handwritten signature.
class SignaturePad extends StatefulWidget {
  const SignaturePad({
    super.key,
    required this.controller,
    this.enabled = true,
  });

  final SignaturePadController controller;
  final bool enabled;

  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<SignaturePad> {
  int? _activePointer;

  Offset _normalize(Offset local, Size size) => Offset(
    size.width == 0 ? 0 : local.dx / size.width,
    size.height == 0 ? 0 : local.dy / size.height,
  );

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: kSignatureCanvasSize.width / kSignatureCanvasSize.height,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // Listener rather than GestureDetector: raw pointer events bypass the
        // gesture arena, so a drag draws instead of being claimed by the
        // scroll view the pad sits inside.
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: !widget.enabled
              ? null
              : (event) {
                  // Ignore a palm or a second finger mid-stroke.
                  if (_activePointer != null) return;
                  _activePointer = event.pointer;
                  widget.controller.beginStroke(
                    _normalize(event.localPosition, size),
                  );
                },
          onPointerMove: !widget.enabled
              ? null
              : (event) {
                  if (event.pointer != _activePointer) return;
                  widget.controller.extendStroke(
                    _normalize(event.localPosition, size),
                  );
                },
          onPointerUp: (event) {
            if (event.pointer != _activePointer) return;
            _activePointer = null;
            widget.controller.endStroke();
          },
          onPointerCancel: (event) {
            if (event.pointer != _activePointer) return;
            _activePointer = null;
            widget.controller.endStroke();
          },
          child: CustomPaint(
            size: size,
            painter: _SignaturePainter(widget.controller),
          ),
        );
      },
    ),
  );
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.controller) : super(repaint: controller);

  final SignaturePadController controller;

  @override
  void paint(Canvas canvas, Size size) {
    // Baseline guide, drawn on screen only and never exported.
    final baseline = size.height * 0.78;
    canvas.drawLine(
      Offset(size.width * 0.06, baseline),
      Offset(size.width * 0.94, baseline),
      Paint()
        ..color = const Color(0xFFBFC7D2)
        ..strokeWidth = 1,
    );
    paintSignature(
      canvas,
      size,
      controller.strokes,
      strokeWidth: math.max(2.0, size.width / 200),
    );
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) =>
      oldDelegate.controller != controller;
}
