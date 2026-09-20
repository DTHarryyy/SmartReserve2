import 'package:flutter/material.dart';

import '../theme/sr_theme.dart';
import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

Future<void> showSrFilterSheet(
  BuildContext context, {
  required String title,
  required Widget child,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final compact = SR.isCompact(width);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.srColors.surface,
    constraints: const BoxConstraints(maxWidth: 640),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(compact ? 20 : 18),
      ),
    ),
    builder: (context) {
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

      return Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 16 : 18,
          10,
          compact ? 16 : 18,
          18 + keyboardInset,
        ),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(compact ? 15 : 16, w: 600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SrIconButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Close filters',
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      );
    },
  );
}

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
  Widget build(BuildContext context) {
    return SrButton(
      label: activeCount == 0 ? label : '$label ($activeCount)',
      icon: const Icon(Icons.tune_rounded, size: 17),
      minHeight: minHeight,
      onPressed: onPressed,
    );
  }
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
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < SR.compactMax;

        if (compact) {
          return _buildCompact(context, constraints);
        }

        return _buildDesktop(context);
      },
    );
  }

  Widget _buildCompact(BuildContext context, BoxConstraints constraints) {
    final searchChildren = children.whereType<FilterSearch>().toList();

    final filterChildren = [
      for (final child in children)
        if (child is! FilterSearch) child,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < searchChildren.length; i++) ...[
            SizedBox(width: double.infinity, child: searchChildren[i]),
            if (i != searchChildren.length - 1) const SizedBox(height: 8),
          ],
          if (searchChildren.isNotEmpty && filterChildren.isNotEmpty)
            const SizedBox(height: 8),
          if (filterChildren.isNotEmpty)
            _MobileFilterRow(children: filterChildren),
          if (count != null) ...[
            const SizedBox(height: 8),
            Text(count!, style: mono(10.5, color: context.srColors.muted)),
          ],
          if (trailing.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: trailing,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDesktop(BuildContext context) {
    final filters = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...children,
        if (count != null)
          Text(count!, style: mono(10.5, color: context.srColors.muted)),
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: filters),
          if (trailing.isNotEmpty) ...[const SizedBox(width: 8), actions],
        ],
      ),
    );
  }
}

class _MobileFilterRow extends StatelessWidget {
  const _MobileFilterRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.length <= 3) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            Expanded(
              flex: _flexForIndex(index: i, count: children.length),
              child: children[i],
            ),
            if (i != children.length - 1) const SizedBox(width: 8),
          ],
        ],
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            SizedBox(width: i == 0 ? 160 : 130, child: children[i]),
            if (i != children.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  int _flexForIndex({required int index, required int count}) {
    if (count == 3) {
      return index == 0 ? 3 : 2;
    }

    return 1;
  }
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
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = SR.isCompact(MediaQuery.sizeOf(context).width);

        final desiredWidth = compact
            ? constraints.maxWidth
            : constraints.maxWidth < width
            ? constraints.maxWidth
            : width;

        return SizedBox(
          width: desiredWidth,
          child: Container(
            height: compact ? 44 : 36,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: context.srColors.surface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: context.srColors.border),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 16,
                  color: context.srColors.muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: controller,
                    onChanged: onChanged,
                    cursorColor: SR.primary,
                    cursorWidth: 1.5,
                    style: sans(12),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      hintText: placeholder,
                      hintStyle: sans(12, color: context.srColors.muted),
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                    ),
                  ),
                ),
                if (controller.text.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Semantics(
                    button: true,
                    label: 'Clear the search',
                    child: Hoverable(
                      builder: (context, hovered) {
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            controller.clear();
                            onChanged('');
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.close_rounded,
                              size: 15,
                              color: hovered
                                  ? context.srColors.ink2
                                  : context.srColors.muted,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
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
        builder: (context, hovered) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: AnimatedContainer(
              duration: SR.stateChange,
              height: compact ? 44 : 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: selected ? SR.primary : context.srColors.surface,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: selected
                      ? SR.primaryHover
                      : hovered
                      ? context.srColors.borderHover
                      : context.srColors.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(
                        12,
                        w: 500,
                        color: selected
                            ? context.srColors.surface
                            : context.srColors.ink3,
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
                            ? context.srColors.surface.withValues(alpha: .7)
                            : context.srColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
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
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: context.srColors.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: context.srColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          isExpanded: true,
          borderRadius: BorderRadius.circular(10),
          dropdownColor: context.srColors.surface,
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 16,
            color: context.srColors.muted,
          ),
          style: sans(
            compact ? 11 : 11.5,
            w: 500,
            color: context.srColors.ink3,
          ),
          onChanged: (newValue) {
            if (newValue != null) {
              onChanged(newValue);
            }
          },
          selectedItemBuilder: (context) {
            return [
              for (final item in items)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    item,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sans(
                      compact ? 11 : 11.5,
                      w: 500,
                      color: context.srColors.ink3,
                    ),
                  ),
                ),
            ];
          },
          items: [
            for (final item in items)
              DropdownMenuItem<String>(
                value: item,
                child: Text(
                  item,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(11.5, w: 500, color: context.srColors.ink3),
                ),
              ),
          ],
        ),
      ),
    );

    Widget result;

    if (compact) {
      result = field;
    } else if (width == null) {
      result = field;
    } else {
      result = LayoutBuilder(
        builder: (context, constraints) {
          return SizedBox(
            width: constraints.maxWidth < width! ? constraints.maxWidth : width,
            child: field,
          );
        },
      );
    }

    return Semantics(label: semanticLabel, child: result);
  }
}
