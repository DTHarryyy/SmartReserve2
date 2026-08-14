import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.number,
    required this.title,
    required this.caption,
    required this.child,
    this.titleSuffix,
    this.dense = false,
    this.anchorKey,
  });

  final String number;
  final String title;

  final String caption;
  final Widget child;
  final Widget? titleSuffix;
  final bool dense;
  final Key? anchorKey;

  @override
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    return Container(
      key: anchorKey,
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(compact ? 14 : (dense ? 16 : 20)),
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SR.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 9,
            runSpacing: 2,
            children: [
              Text(number, style: mono(10, w: 500, color: SR.blue)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: sans(13.5, w: 600, tracking: -.01)),
                  ?titleSuffix,
                ],
              ),
              Text(caption, style: sans(11, color: SR.muted)),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class FieldRow extends StatelessWidget {
  const FieldRow({super.key, required this.children, this.stacked = false});

  final List<Widget> children;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (stacked || constraints.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                children[i],
              ],
            ],
          );
        }
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += 2) {
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: children[i]),
                const SizedBox(width: 12),
                Expanded(
                  child: i + 1 < children.length
                      ? children[i + 1]
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          );
          if (i + 2 < children.length) rows.add(const SizedBox(height: 12));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}
