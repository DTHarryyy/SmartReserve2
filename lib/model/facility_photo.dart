import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

@immutable
class FacilityPhoto {
  const FacilityPhoto({
    required this.id,
    this.bytes,
    this.path,
    this.label,
    this.placeholderHue,
    this.storagePath,
    this.publicUrl,
  });

  factory FacilityPhoto.remote({
    required String storagePath,
    required String publicUrl,
  }) => FacilityPhoto(
    id: storagePath,
    storagePath: storagePath,
    publicUrl: publicUrl,
    label: storagePath.split('/').last,
  );

  factory FacilityPhoto.placeholder(int seed) => FacilityPhoto(
    id: 'ph-$seed-${DateTime.now().microsecondsSinceEpoch}',
    label: 'placeholder',
    placeholderHue: (seed * 47) % 360,
  );

  final String id;

  final Uint8List? bytes;

  final String? path;

  final String? label;

  final int? placeholderHue;

  final String? storagePath;

  final String? publicUrl;

  bool get isPlaceholder => placeholderHue != null;

  bool get isRemote => storagePath != null;

  Future<Uint8List?> readBytes() async {
    if (bytes != null) return bytes;
    if (path != null && !kIsWeb) return File(path!).readAsBytes();
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'label': label,
    'hue': placeholderHue,
    'storagePath': storagePath,
    'publicUrl': publicUrl,
  };

  static FacilityPhoto? fromJson(Map<String, dynamic> json) {
    final hue = json['hue'] as int?;
    final path = json['path'] as String?;
    final storagePath = json['storagePath'] as String?;
    final publicUrl = json['publicUrl'] as String?;
    if (storagePath != null && publicUrl != null) {
      return FacilityPhoto.remote(
        storagePath: storagePath,
        publicUrl: publicUrl,
      );
    }
    if (hue == null) {
      if (path == null) return null;
      if (!kIsWeb && !File(path).existsSync()) return null;
    }
    return FacilityPhoto(
      id: json['id'] as String? ?? UniqueKey().toString(),
      path: path,
      label: json['label'] as String?,
      placeholderHue: hue,
    );
  }
}

class PlaceholderStripes extends StatelessWidget {
  const PlaceholderStripes({
    super.key,
    required this.hue,
    this.caption = 'facility photo',
    this.captionSize = 11,
  });

  final int hue;
  final String caption;
  final double captionSize;

  @override
  Widget build(BuildContext context) {
    final base = HSLColor.fromAHSL(1, hue.toDouble(), .14, .92).toColor();
    final stripe = HSLColor.fromAHSL(1, hue.toDouble(), .16, .88).toColor();
    final ink = HSLColor.fromAHSL(1, hue.toDouble(), .10, .52).toColor();
    return CustomPaint(
      painter: _StripePainter(base: base, stripe: stripe),
      child: Center(
        child: Text(
          caption,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'IBM Plex Mono',
            fontSize: captionSize,
            color: ink,
          ),
        ),
      ),
    );
  }
}

class FacilityCoverArt extends StatelessWidget {
  const FacilityCoverArt({super.key, required this.hue, required this.glyph});

  final int hue;
  final IconData glyph;

  @override
  Widget build(BuildContext context) {
    final start = HSLColor.fromAHSL(1, hue.toDouble(), .52, .58).toColor();
    final end = HSLColor.fromAHSL(1, (hue + 28) % 360, .58, .42).toColor();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [start, end],
        ),
      ),
      child: Center(
        child: Icon(
          glyph,
          size: 46,
          color: Colors.white.withValues(alpha: .22),
        ),
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  const _StripePainter({required this.base, required this.stripe});

  final Color base;
  final Color stripe;

  static const _period = 14.0;
  static const _angle = 35 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(_angle);
    final reach = size.width + size.height;
    final paint = Paint()..color = stripe;
    for (var x = -reach; x < reach; x += _period) {
      canvas.drawRect(Rect.fromLTWH(x, -reach, _period / 2, reach * 2), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripePainter old) =>
      old.base != base || old.stripe != stripe;
}

class FacilityPhotoImage extends StatelessWidget {
  const FacilityPhotoImage({
    super.key,
    required this.photo,
    this.captionSize = 11,
  });

  final FacilityPhoto photo;
  final double captionSize;

  @override
  Widget build(BuildContext context) {
    if (photo.placeholderHue != null) {
      return PlaceholderStripes(
        hue: photo.placeholderHue!,
        captionSize: captionSize,
      );
    }
    if (photo.bytes != null) {
      return Image.memory(photo.bytes!, fit: BoxFit.cover);
    }
    if (photo.publicUrl != null) {
      return Image.network(
        photo.publicUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            const PlaceholderStripes(hue: 210, caption: 'image unavailable'),
      );
    }
    if (photo.path != null && !kIsWeb) {
      return Image.file(File(photo.path!), fit: BoxFit.cover);
    }
    return const PlaceholderStripes(hue: 210, caption: 'image unavailable');
  }
}
