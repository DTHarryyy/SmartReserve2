import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

Future<void> showSrFilterSheet(
  BuildContext context, {
  required String title,
  required Widget child,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: SR.surface,
  constraints: const BoxConstraints(maxWidth: 640),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
  ),
  builder: (context) => Padding(
    padding: EdgeInsets.fromLTRB(
      18,
      10,
      18,
      18 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: SR.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Text(title, style: sans(16, w: 600))),
              SrIconButton(
                icon: Icons.close_rounded,
                tooltip: 'Close filters',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  ),
);

class CompactFilterButton extends StatelessWidget {
  const CompactFilterButton({
    super.key,
    required this.onPressed,
    this.activeCount = 0,
    this.label = 'Filters',
    this.minHeight = 44,
  });

  final VoidCallback onPressed;
  final int activeCount;
  final String label;

  final double minHeight;

  @override
  Widget build(BuildContext context) => SrButton(
    label: activeCount == 0 ? label : '$label ($activeCount)',
    icon: const Icon(Icons.tune_rounded, size: 17),
    minHeight: minHeight,
    onPressed: onPressed,
  );
}

class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.children,
    this.trailing = const [],
    this.count,
  });

  final List<Widget> children;

  final List<Widget> trailing;

  final String? count;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < SR.compactMax;
      final filters = Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...children,
          if (count != null) Text(count!, style: mono(10.5, color: SR.muted)),
        ],
      );
      final actions = Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        children: trailing,
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  filters,
                  if (trailing.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    actions,
                  ],
                ],
              )
            : Row(
                children: [
                  Expanded(child: filters),
                  if (trailing.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    actions,
                  ],
                ],
              ),
      );
    },
  );
}

class FilterSearch extends StatelessWidget {
  const FilterSearch({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.placeholder,
    this.width = 300,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String placeholder;
  final double width;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SizedBox(
      width: constraints.maxWidth < width ? constraints.maxWidth : width,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: SR.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: SR.border),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 15, color: SR.muted),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                cursorColor: SR.blue,
                cursorWidth: 1.5,
                style: sans(12),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: placeholder,
                  hintStyle: sans(12, color: SR.muted),
                ),
              ),
            ),
            if (controller.text.isNotEmpty)
              Semantics(
                button: true,
                label: 'Clear the search',
                child: Hoverable(
                  builder: (context, hovered) => GestureDetector(
                    onTap: () {
                      controller.clear();
                      onChanged('');
                    },
                    child: Text(
                      '✕',
                      style: sans(11, color: hovered ? SR.ink2 : SR.muted),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? count;

  @override
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    return Semantics(
      button: true,
      selected: selected,
      child: Hoverable(
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: SR.stateChange,
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: compact ? 11 : 8,
            ),
            decoration: BoxDecoration(
              color: selected ? SR.blue : SR.surface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: selected
                    ? SR.blueDark
                    : (hovered ? SR.borderHover : SR.border),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sans(
                      12,
                      w: 500,
                      color: selected ? SR.surface : SR.ink3,
                    ),
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 7),
                  Text(
                    count!,
                    style: mono(
                      10.5,
                      w: 500,
                      color: selected
                          ? SR.surface.withValues(alpha: .7)
                          : SR.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FilterSelect extends StatelessWidget {
  const FilterSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.semanticLabel,
    this.width,
  });

  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;
  final String semanticLabel;

  final double? width;

  @override
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final field = Container(
      height: compact ? 44 : 36,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: SR.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          isExpanded: true,
          borderRadius: BorderRadius.circular(10),
          dropdownColor: SR.surface,
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 16,
            color: SR.muted,
          ),
          style: sans(11.5, w: 500, color: SR.ink3),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
          selectedItemBuilder: (context) => [
            for (final item in items)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  item,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(11.5, w: 500, color: SR.ink3),
                ),
              ),
          ],
          items: [
            for (final item in items)
              DropdownMenuItem(
                value: item,
                child: Text(
                  item,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(11.5, w: 500, color: SR.ink3),
                ),
              ),
          ],
        ),
      ),
    );
    final boxed = width == null
        ? field
        : LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              width: constraints.maxWidth < width!
                  ? constraints.maxWidth
                  : width,
              child: field,
            ),
          );
    return Semantics(label: semanticLabel, child: boxed);
  }
}
