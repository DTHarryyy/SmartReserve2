import 'package:flutter/material.dart';

import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import 'conflict_engine.dart';
import 'reservation_checks.dart';

class DayTimeline extends StatelessWidget {
  const DayTimeline({
    super.key,
    required this.assessment,
    required this.confirmed,
  });

  final ReservationAssessment assessment;

  final List<Hold> confirmed;

  @override
  Widget build(BuildContext context) {
    final facility = assessment.facility;
    final open = (facility?.openHour ?? dayStartHour).toDouble();
    final close = (facility?.closeHour ?? dayEndHour).toDouble();
    final span = (close - open).clamp(1, 24).toDouble();

    double fraction(double hour) => ((hour - open) / span).clamp(0.0, 1.0);

    final ticks = <int>[
      for (var h = open.floor(); h <= close.floor(); h += 2) h,
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        Widget block({
          required double from,
          required double to,
          required String label,
          required Color background,
          required Color border,
          required Color foreground,
          required double top,
          required double height,
          bool mono = false,
        }) {
          final left = fraction(from) * width;
          final right = fraction(to) * width;
          return Positioned(
            left: left,
            width: (right - left).clamp(6.0, width),
            top: top,
            height: height,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: border),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(9.5, w: 500, color: foreground),
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 92,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: SR.surfaceSubtle,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: SR.hairline),
                      ),
                    ),
                  ),
                  for (final tick in ticks) ...[
                    Positioned(
                      left: fraction(tick.toDouble()) * width,
                      top: 0,
                      bottom: 0,
                      width: 1,
                      child: const ColoredBox(color: SR.hairline),
                    ),
                    Positioned(
                      left: fraction(tick.toDouble()) * width + 3,
                      top: 4,
                      child: Text(
                        '${tick.toString().padLeft(2, '0')}:00',
                        style: mono(8.5, color: SR.mutedLight),
                      ),
                    ),
                  ],
                  for (final booking in confirmed)
                    block(
                      from: booking.startAt,
                      to: booking.endAt,
                      label: booking.label,
                      background: SR.divider,
                      border: SR.hairline,
                      foreground: SR.ink3,
                      top: 22,
                      height: 24,
                    ),
                  block(
                    from: assessment.request.startAt,
                    to: assessment.request.endAt,
                    label:
                        '${assessment.request.start}–'
                        '${assessment.request.end} · this request',
                    background: assessment.hasConflict ? SR.red : SR.blue,
                    border: assessment.hasConflict ? SR.red : SR.blueDark,
                    foreground: SR.surface,
                    top: 56,
                    height: 26,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Grey blocks are confirmed bookings · the coloured block is this '
              'request',
              style: sans(10.5, color: SR.muted),
            ),
          ],
        );
      },
    );
  }
}
