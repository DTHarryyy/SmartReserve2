import 'package:flutter/material.dart';

class SrLogo extends StatelessWidget {
  const SrLogo({super.key, this.size = 40, this.radius});

  final double size;
  final double? radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius ?? size * 0.27),
    child: Image.asset(
      'assets/smartreserve logo.png',
      width: size,
      height: size,
      fit: BoxFit.cover,
    ),
  );
}
