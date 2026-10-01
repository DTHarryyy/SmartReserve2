import 'package:flutter/material.dart';

import '../theme/sr_theme.dart';
import '../theme/sr_tokens.dart';
import 'sr_logo.dart';

String timeGreeting([DateTime? now]) {
  final hour = (now ?? DateTime.now()).hour;
  if (hour < 12) return 'Good morning';
  if (hour < 18) return 'Good afternoon';
  return 'Good evening';
}

/// CSU and SmartReserve logos beside the app name and a "Good evening, Name"
/// line, used in the admin and student headers.
class BrandGreeting extends StatelessWidget {
  const BrandGreeting({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Image.asset(
        'assets/csu_logo_transparent.png',
        width: SR.controlSm,
        height: SR.controlSm,
        fit: BoxFit.contain,
      ),
      const SizedBox(width: SR.space12),
      const SrLogo(size: SR.controlSm, radius: SR.rSm),
      const SizedBox(width: SR.space12),
      Flexible(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SmartReserve',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sans(
                15,
                w: 600,
                tracking: -.01,
                color: context.srColors.text,
              ),
            ),
            Text(
              '${timeGreeting()}, $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SrType.caption(color: context.srColors.textMuted),
            ),
          ],
        ),
      ),
    ],
  );
}
