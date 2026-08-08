import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...children,
              if (count != null)
                Text(count!, style: mono(10.5, color: SR.muted)),
            ],
          ),
        ),
        for (final widget in trailing) ...[const SizedBox(width: 8), widget],
      ],
    ),
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
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: SR.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, size: 15, color: SR.muted),
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
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
              Text(
                label,
                style: sans(12, w: 500, color: selected ? SR.surface : SR.ink3),
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

class FilterSelect extends StatelessWidget {
  const FilterSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.semanticLabel,
  });

  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    child: Container(
      height: 36,
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
          icon: const Icon(
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
    ),
  );
}
