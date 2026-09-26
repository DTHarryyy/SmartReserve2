import 'package:flutter/material.dart';

class SrLogo extends StatelessWidget {
  const SrLogo({super.key, this.size = 40, this.radius});

  static const asset = 'assets/smart reserve logo.png';

  /// The logo decoded at display size; the source is far larger than any use.
  /// Shared with the boot precache so both hit the same image cache entry.
  static ImageProvider imageFor(double size, double devicePixelRatio) =>
      ResizeImage(
        const AssetImage(asset),
        width: (size * devicePixelRatio).ceil(),
      );

  final double size;
  final double? radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius ?? size * 0.27),
    child: Image(
      image: imageFor(size, MediaQuery.devicePixelRatioOf(context)),
      width: size,
      height: size,
      fit: BoxFit.cover,
    ),
  );
}
