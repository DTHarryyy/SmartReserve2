import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

import '../theme/sr_theme.dart';

enum ColumnHide { never, small, medium }

@immutable
class ColSpec {
  const ColSpec(
    this.label, {
    this.flex = 0,
    this.width,
    this.hide = ColumnHide.never,
    this.alignRight = false,
  });

  final String label;

  final int flex;
  final double? width;
  final ColumnHide hide;
  final bool alignRight;

  bool visibleAt(double viewport) => switch (hide) {
    ColumnHide.never => true,
    ColumnHide.small => viewport >= SR.tabletMin,
    ColumnHide.medium => viewport >= SR.desktopMin,
  };
}

class TableRowLayout extends StatelessWidget {
  const TableRowLayout({
    super.key,
    required this.columns,
    required this.cells,
    required this.viewport,
  });

  final List<ColSpec> columns;

  final List<Widget> cells;
  final double viewport;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < columns.length; i++) {
      final column = columns[i];
      if (!column.visibleAt(viewport)) continue;
      if (children.isNotEmpty) children.add(const SizedBox(width: 12));
      final cell = Align(
        alignment: column.alignRight
            ? Alignment.centerRight
            : Alignment.centerLeft,
        child: cells[i],
      );
      children.add(
        column.flex > 0
            ? Expanded(flex: column.flex, child: cell)
            : SizedBox(width: column.width, child: cell),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );
  }
}

class RecordTable extends StatelessWidget {
  const RecordTable({
    super.key,
    required this.columns,
    required this.children,
    this.footerNote,
  });

  final List<ColSpec> columns;
  final List<Widget> children;
  final String? footerNote;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context).width;
    final compact = SR.isCompact(viewport);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          clipBehavior: compact ? Clip.none : Clip.antiAlias,
          decoration: BoxDecoration(
            color: compact ? Colors.transparent : context.srColors.surface,
            borderRadius: BorderRadius.circular(SR.rLg),
            border: compact ? null : Border.all(color: context.srColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!compact)
                Container(
                  key: const Key('record-table-header'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: context.srColors.surfaceSubtle,
                    border: Border(
                      bottom: BorderSide(color: context.srColors.hairline),
                    ),
                  ),
                  child: TableRowLayout(
                    columns: columns,
                    viewport: viewport,
                    cells: [
                      for (final column in columns)
                        Text(
                          column.label,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: mono(
                            10,
                            w: 500,
                            tracking: .04,
                            color: context.srColors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ...children,
            ],
          ),
        ),
        if (footerNote != null) ...[
          const SizedBox(height: 12),
          Text(
            footerNote!,
            style: sans(11, height: 1.6, color: context.srColors.muted),
          ),
        ],
      ],
    );
  }
}

class RecordRow extends StatelessWidget {
  const RecordRow({
    super.key,
    required this.columns,
    required this.cells,
    this.onTap,
    this.vertical = 13,
    this.compactChild,
  });

  final List<ColSpec> columns;
  final List<Widget> cells;
  final VoidCallback? onTap;
  final double vertical;
  final Widget? compactChild;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context).width;
    final compact = SR.isCompact(viewport);
    return Hoverable(
      enabled: onTap != null,
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: compact ? const EdgeInsets.only(bottom: 8) : EdgeInsets.zero,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 14 : 16,
            vertical: compact ? 14 : vertical,
          ),
          decoration: BoxDecoration(
            color: hovered
                ? context.srColors.surfaceSubtle
                : context.srColors.surface,
            borderRadius: compact ? BorderRadius.circular(SR.rLg) : null,
            border: compact
                ? Border.all(
                    color: hovered
                        ? context.srColors.primarySoft
                        : context.srColors.border,
                  )
                : Border(bottom: BorderSide(color: context.srColors.divider)),
          ),
          child: compact
              ? compactChild ??
                    _MobileRecordLayout(columns: columns, cells: cells)
              : TableRowLayout(
                  columns: columns,
                  viewport: viewport,
                  cells: cells,
                ),
        ),
      ),
    );
  }
}

class _MobileRecordLayout extends StatelessWidget {
  const _MobileRecordLayout({required this.columns, required this.cells});

  final List<ColSpec> columns;
  final List<Widget> cells;

  @override
  Widget build(BuildContext context) {
    final actionIndex = columns.isNotEmpty && columns.last.label == 'ACTIONS'
        ? columns.length - 1
        : null;
    final details = <int>[
      for (var i = 1; i < columns.length; i++)
        if (i != actionIndex) i,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: cells.first),
            if (actionIndex != null) ...[
              const SizedBox(width: 10),
              cells[actionIndex],
            ],
          ],
        ),
        if (details.isNotEmpty) ...[
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final twoColumns = constraints.maxWidth >= 340;
              final itemWidth = twoColumns
                  ? (constraints.maxWidth - 12) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  for (final index in details)
                    SizedBox(
                      width: itemWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(columns[index].label, style: keyLabel),
                          const SizedBox(height: 4),
                          cells[index],
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}

class SkeletonRow extends StatefulWidget {
  const SkeletonRow({
    super.key,
    required this.columns,
    required this.leadWidth,
  });

  final List<ColSpec> columns;

  final double leadWidth;

  @override
  State<SkeletonRow> createState() => _SkeletonRowState();
}

class _SkeletonRowState extends State<SkeletonRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context).width;
    final compact = SR.isCompact(viewport);
    return Container(
      margin: compact ? const EdgeInsets.only(bottom: 8) : EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: context.srColors.surface,
        borderRadius: compact ? BorderRadius.circular(12) : null,
        border: compact
            ? Border.all(color: context.srColors.border)
            : Border(bottom: BorderSide(color: context.srColors.divider)),
      ),
      child: compact
          ? _MobileSkeleton(shimmer: _shimmer)
          : TableRowLayout(
              columns: widget.columns,
              viewport: viewport,
              cells: [
                for (var i = 0; i < widget.columns.length; i++)
                  i == 0
                      ? AnimatedBuilder(
                          animation: _shimmer,
                          builder: (context, _) => FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: widget.leadWidth,
                            child: Container(
                              height: 11,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                gradient: LinearGradient(
                                  colors: [
                                    context.srColors.hairline,
                                    context.srColors.surfaceSubtle,
                                    context.srColors.hairline,
                                  ],
                                  stops: [
                                    (_shimmer.value - .3).clamp(0.0, 1.0),
                                    _shimmer.value,
                                    (_shimmer.value + .3).clamp(0.0, 1.0),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        )
                      : Container(
                          height: 11,
                          decoration: BoxDecoration(
                            color: context.srColors.divider,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
              ],
            ),
    );
  }
}

class _MobileSkeleton extends StatelessWidget {
  const _MobileSkeleton({required this.shimmer});

  final Animation<double> shimmer;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: shimmer,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FractionallySizedBox(
          widthFactor: .65,
          child: Container(
            height: 13,
            decoration: BoxDecoration(
              color: context.srColors.hairline,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (var i = 0; i < 2; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color.lerp(
                      context.srColors.hairline,
                      context.srColors.surfaceSubtle,
                      shimmer.value,
                    ),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

class ListEmptyState extends StatelessWidget {
  const ListEmptyState({
    super.key,
    this.icon,
    @Deprecated('Pass icon instead — an IconData reads better than a glyph.')
    this.glyph,
    required this.title,
    required this.body,
    this.action,
    this.footnote,
  }) : assert(
         icon != null || glyph != null,
         'ListEmptyState needs either an icon or a glyph.',
       );

  final IconData? icon;

  @Deprecated('Pass icon instead — an IconData reads better than a glyph.')
  final String? glyph;
  final String title;
  final String body;
  final Widget? action;
  final Widget? footnote;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? SR.space20 : SR.space24,
        vertical: compact ? SR.space32 : SR.space48 + SR.space16,
      ),
      decoration: compact
          ? BoxDecoration(
              color: context.srColors.surface,
              borderRadius: BorderRadius.circular(SR.rMd),
              border: Border.all(color: context.srColors.border),
            )
          : null,
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.srColors.primaryTint,
              shape: BoxShape.circle,
            ),
            child: icon != null
                ? Icon(icon, size: 24, color: context.srColors.primaryDeep)
                : Text(
                    // ignore: deprecated_member_use_from_same_package
                    glyph!,
                    style: sans(20, color: context.srColors.primaryDeep),
                  ),
          ),
          const SizedBox(height: SR.space16),
          Text(title, style: SrType.subhead()),
          const SizedBox(height: SR.space6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: SrType.bodySm(),
            ),
          ),
          if (action != null) ...[const SizedBox(height: SR.space20), action!],
          if (footnote != null) ...[
            const SizedBox(height: SR.space12),
            footnote!,
          ],
        ],
      ),
    );
  }
}
