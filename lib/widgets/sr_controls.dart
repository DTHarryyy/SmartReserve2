import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/sr_tokens.dart';

class Hoverable extends StatefulWidget {
  const Hoverable({
    super.key,
    required this.builder,
    this.cursor = SystemMouseCursors.click,
    this.enabled = true,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;
  final bool enabled;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.enabled ? widget.cursor : SystemMouseCursors.basic,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: widget.builder(context, widget.enabled && _hovered),
  );
}

enum SrButtonKind {
  primary,
  secondary,
  ghost,
  danger,
  dangerSolid,

  success,

  caution,
}

class SrButton extends StatefulWidget {
  const SrButton({
    super.key,
    required this.label,
    this.onPressed,
    this.kind = SrButtonKind.secondary,
    this.icon,
    this.trailing,
    this.dense = false,
    this.expand = false,
    this.minHeight,
    this.fontSize = 12,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final SrButtonKind kind;
  final Widget? icon;

  final Widget? trailing;
  final bool dense;
  final bool expand;
  final double? minHeight;
  final double fontSize;
  final String? tooltip;

  @override
  State<SrButton> createState() => _SrButtonState();
}

class _SrButtonState extends State<SrButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final primary = widget.kind == SrButtonKind.primary;

    Widget content(bool hovered) {
      final (Color bg, Color fg, Color? bd) = switch (widget.kind) {
        SrButtonKind.primary => (
          hovered ? SR.blueDark : SR.blue,
          SR.surface,
          SR.blueDark,
        ),
        SrButtonKind.secondary => (
          hovered ? SR.surfaceSubtle : SR.surface,
          SR.ink2,
          hovered ? SR.borderHover : SR.border,
        ),
        SrButtonKind.ghost => (
          hovered ? SR.dividerSoft : Colors.transparent,
          SR.ink2,
          null,
        ),
        SrButtonKind.danger => (
          hovered ? SR.redTint : SR.surface,
          SR.red,
          SR.redLine,
        ),
        SrButtonKind.dangerSolid => (SR.red, SR.surface, SR.red),
        SrButtonKind.success => (
          hovered ? const Color(0xFF0A5C3A) : SR.greenDark,
          SR.surface,
          const Color(0xFF0A5C3A),
        ),
        SrButtonKind.caution => (
          hovered ? SR.amberIcon : SR.amberTint,
          SR.amberTitle,
          SR.amberLine,
        ),
      };

      return AnimatedContainer(
        duration: SR.stateChange,
        curve: SR.easing,
        constraints: BoxConstraints(minHeight: widget.minHeight ?? 0),
        transform: Matrix4.translationValues(0, primary && _pressed ? 1 : 0, 0),
        padding: EdgeInsets.symmetric(
          horizontal: widget.dense ? 11 : 15,
          vertical: widget.minHeight != null ? 0 : (widget.dense ? 6 : 8),
        ),
        decoration: BoxDecoration(
          color: enabled ? bg : SR.dividerSoft,
          borderRadius: BorderRadius.circular(8),
          border: bd == null
              ? null
              : Border.all(color: enabled ? bd : SR.border),
          boxShadow: primary && enabled ? SR.cardShadow : null,
        ),
        child: Row(
          mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.icon != null) ...[
              widget.icon!,
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(
                  widget.fontSize,
                  w:
                      primary ||
                          widget.kind == SrButtonKind.dangerSolid ||
                          widget.kind == SrButtonKind.danger
                      ? 600
                      : 500,
                  color: enabled ? fg : SR.muted,
                ),
              ),
            ),
            if (widget.trailing != null) ...[
              const SizedBox(width: 8),
              widget.trailing!,
            ],
          ],
        ),
      );
    }

    final button = Hoverable(
      enabled: enabled,
      builder: (context, hovered) => GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: content(hovered),
      ),
    );

    final semantic = Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: button,
    );
    return widget.tooltip == null
        ? semantic
        : Tooltip(message: widget.tooltip!, child: semantic);
  }
}

class SrIconButton extends StatelessWidget {
  const SrIconButton({
    super.key,
    this.glyph,
    this.icon,
    required this.onPressed,
    required this.tooltip,
    this.size = 32,
    this.fontSize = 12,
    this.background = SR.surface,
    this.foreground = SR.ink2,
    this.hoverForeground = SR.blue,
    this.border = SR.border,
    this.radius = 9,
    this.shadow,
  });

  final String? glyph;
  final IconData? icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;
  final double fontSize;
  final Color background;
  final Color foreground;
  final Color hoverForeground;
  final Color? border;
  final double radius;
  final List<BoxShadow>? shadow;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      child: Hoverable(
        enabled: onPressed != null,
        builder: (context, hovered) => GestureDetector(
          onTap: onPressed,
          child: AnimatedContainer(
            duration: SR.stateChange,
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered ? SR.dividerSoft : background,
              borderRadius: BorderRadius.circular(radius),
              border: border == null ? null : Border.all(color: border!),
              boxShadow: shadow,
            ),
            child: Builder(
              builder: (context) {
                final tint = onPressed == null
                    ? SR.mutedLight
                    : (hovered ? hoverForeground : foreground);
                return icon != null
                    ? Icon(icon, size: fontSize + 3, color: tint)
                    : Text(glyph ?? '', style: sans(fontSize, color: tint));
              },
            ),
          ),
        ),
      ),
    ),
  );
}

class DashedBox extends StatelessWidget {
  const DashedBox({
    super.key,
    required this.child,
    this.radius = 11,
    this.color = SR.dashed,
    this.background = Colors.transparent,
    this.padding = const EdgeInsets.all(18),
    this.dash = 5,
    this.gap = 4,
    this.stretch = true,
  });

  final Widget child;
  final double radius;
  final Color color;
  final Color background;
  final EdgeInsets padding;
  final double dash;
  final double gap;

  final bool stretch;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: SR.stateChange,
    width: stretch ? double.infinity : null,
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(radius),
    ),
    child: CustomPaint(
      painter: _DashedBorderPainter(
        radius: radius,
        color: color,
        dash: dash,
        gap: gap,
      ),
      child: Padding(padding: padding, child: child),
    ),
  );
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({
    required this.radius,
    required this.color,
    required this.dash,
    required this.gap,
  });

  final double radius;
  final Color color;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

class SrLabel extends StatelessWidget {
  const SrLabel(this.text, {super.key, this.required = false, this.meta});

  final String text;
  final bool required;
  final Widget? meta;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Text.rich(
          TextSpan(
            text: text,
            children: [
              if (required)
                TextSpan(
                  text: ' *',
                  style: sans(11.5, w: 500, color: SR.red),
                ),
            ],
          ),
          style: sans(11.5, w: 500, color: SR.ink2),
        ),
        if (meta != null) ...[const Spacer(), meta!],
      ],
    ),
  );
}

class SrErrorText extends StatelessWidget {
  const SrErrorText(this.message, {super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 5),
            child: Text('⚠', style: sans(10, color: SR.red)),
          ),
          Expanded(
            child: Text(message!, style: sans(11, height: 1.45, color: SR.red)),
          ),
        ],
      ),
    );
  }
}

class SrTextField extends StatefulWidget {
  const SrTextField({
    super.key,
    required this.controller,
    this.onChanged,
    this.placeholder,
    this.hasError = false,
    this.mono = false,
    this.fontSize = 13,
    this.minLines,
    this.maxLines = 1,
    this.keyboardType,
    this.inputFormatters,
    this.semanticLabel,
    this.suffix,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.focusNode,
    this.onSubmitted,
    this.autofocus = false,
    this.readOnly = false,
    this.onTap,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final String? placeholder;
  final bool hasError;
  final bool mono;
  final double fontSize;
  final int? minLines;
  final int? maxLines;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? semanticLabel;
  final Widget? suffix;
  final EdgeInsets padding;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool readOnly;
  final VoidCallback? onTap;

  @override
  State<SrTextField> createState() => _SrTextFieldState();
}

class _SrTextFieldState extends State<SrTextField> {
  late final FocusNode _node = widget.focusNode ?? FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  void _sync() {
    if (_node.hasFocus != _focused) setState(() => _focused = _node.hasFocus);
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.mono
        ? mono(widget.fontSize, color: SR.ink)
        : sans(widget.fontSize, height: widget.maxLines == 1 ? null : 1.6);
    return AnimatedContainer(
      duration: SR.stateChange,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: widget.hasError
              ? SR.red
              : (_focused ? SR.blue : SR.borderField),
        ),
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: (widget.hasError ? SR.red : SR.blue).withValues(
                    alpha: .12,
                  ),
                  spreadRadius: 3,
                ),
              ]
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _node,
              autofocus: widget.autofocus,
              readOnly: widget.readOnly,
              onTap: widget.onTap,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              keyboardType: widget.keyboardType,
              inputFormatters: widget.inputFormatters,
              cursorColor: SR.blue,
              cursorWidth: 1.5,
              style: style,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: widget.placeholder,
                hintStyle: style.copyWith(color: SR.mutedLight),
                labelText: null,
              ),
            ),
          ),
          if (widget.suffix != null) widget.suffix!,
        ],
      ),
    );
  }
}

class SrSelect<T> extends StatelessWidget {
  const SrSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.labelOf,
    this.placeholder,
    this.hasError = false,
    this.semanticLabel,
    this.fontSize = 13,
    this.subtitleOf,
  });

  final T? value;
  final List<T> items;
  final ValueChanged<T?> onChanged;
  final String Function(T) labelOf;

  final String? Function(T)? subtitleOf;
  final String? placeholder;
  final bool hasError;
  final String? semanticLabel;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    child: Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: hasError ? SR.red : SR.borderField),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          borderRadius: BorderRadius.circular(10),
          dropdownColor: SR.surface,
          icon: const Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 16,
            color: SR.muted,
          ),
          hint: Text(
            placeholder ?? '',
            style: sans(fontSize, color: SR.mutedLight),
          ),
          style: sans(fontSize),
          onChanged: onChanged,
          selectedItemBuilder: (context) => [
            for (final item in items)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  labelOf(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(fontSize),
                ),
              ),
          ],
          items: [
            for (final item in items)
              DropdownMenuItem<T>(
                value: item,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        labelOf(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sans(fontSize),
                      ),
                    ),
                    if (subtitleOf?.call(item) != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        subtitleOf!(item)!,
                        style: mono(9, w: 500, tracking: .04, color: SR.amber),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class SrToggle extends StatelessWidget {
  const SrToggle({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    toggled: value,
    label: label,
    child: GestureDetector(
      onTap: () => onChanged(!value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: SR.easing,
          width: 38,
          height: 22,
          decoration: BoxDecoration(
            color: value ? SR.blue : SR.border,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: SR.easing,
                top: 3,
                left: value ? 19 : 3,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: SR.surface,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x4710141A),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class SrPill extends StatelessWidget {
  const SrPill({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    this.monospace = false,
    this.fontSize = 10.5,
    this.dot,
  });

  final String label;
  final Color background;
  final Color foreground;
  final bool monospace;
  final double fontSize;
  final Color? dot;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: monospace ? 7 : 9, vertical: 3),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot != null) ...[
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monospace
                ? mono(fontSize, w: 600, tracking: .04, color: foreground)
                : sans(fontSize, w: 600, color: foreground),
          ),
        ),
      ],
    ),
  );
}

class SrKeyCell extends StatelessWidget {
  const SrKeyCell({
    super.key,
    required this.label,
    required this.value,
    this.valueColor = SR.ink,
    this.valueMono = false,
  });

  final String label;
  final String value;
  final Color valueColor;
  final bool valueMono;

  @override
  Widget build(BuildContext context) => Container(
    color: SR.surface,
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: keyLabel),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: valueMono
              ? mono(12.5, w: 500, color: valueColor)
              : sans(12.5, w: 500, color: valueColor),
        ),
      ],
    ),
  );
}

class SrCellGrid extends StatelessWidget {
  const SrCellGrid({super.key, required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final slice = children.sublist(
        i,
        (i + columns).clamp(0, children.length),
      );
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var c = 0; c < columns; c++) ...[
                if (c > 0) const SizedBox(width: 1),
                Expanded(
                  child: c < slice.length
                      ? slice[c]
                      : const ColoredBox(color: SR.surface),
                ),
              ],
            ],
          ),
        ),
      );
      if (i + columns < children.length) rows.add(const SizedBox(height: 1));
    }
    return Container(
      decoration: BoxDecoration(
        color: SR.hairline,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SR.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}
