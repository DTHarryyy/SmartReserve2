import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: SR.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: SR.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                decoration: const BoxDecoration(
                  color: SR.surfaceSubtle,
                  border: Border(bottom: BorderSide(color: SR.hairline)),
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
                        style: mono(10, w: 500, tracking: .04, color: SR.muted),
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
          Text(footerNote!, style: sans(11, height: 1.6, color: SR.muted)),
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
  });

  final List<ColSpec> columns;
  final List<Widget> cells;
  final VoidCallback? onTap;
  final double vertical;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context).width;
    return Hoverable(
      enabled: onTap != null,
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: vertical),
          decoration: BoxDecoration(
            color: hovered ? SR.surfaceSubtle : SR.surface,
            border: const Border(bottom: BorderSide(color: SR.divider)),
          ),
          child: TableRowLayout(
            columns: columns,
            viewport: viewport,
            cells: cells,
          ),
        ),
      ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: SR.divider)),
      ),
      child: TableRowLayout(
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
                            colors: const [
                              SR.hairline,
                              Color(0xFFF7F8FA),
                              SR.hairline,
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
                      color: SR.divider,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
        ],
      ),
    );
  }
}

class ListEmptyState extends StatelessWidget {
  const ListEmptyState({
    super.key,
    required this.glyph,
    required this.title,
    required this.body,
    this.action,
    this.footnote,
  });

  final String glyph;
  final String title;
  final String body;
  final Widget? action;
  final Widget? footnote;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 64),
    child: Column(
      children: [
        DashedBox(
          stretch: false,
          radius: 14,
          padding: const EdgeInsets.all(14),
          child: Text(glyph, style: sans(20, color: SR.muted)),
        ),
        const SizedBox(height: 16),
        Text(title, style: sans(15, w: 600)),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: sans(12.5, height: 1.6, color: SR.ink4),
          ),
        ),
        if (action != null) ...[const SizedBox(height: 18), action!],
        if (footnote != null) ...[const SizedBox(height: 12), footnote!],
      ],
    ),
  );
}
