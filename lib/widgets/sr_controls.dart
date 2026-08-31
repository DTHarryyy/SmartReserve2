import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/sr_theme.dart';
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
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final effectiveMinHeight = widget.minHeight ?? (compact ? 44.0 : 0.0);
    final c = context.srColors;

    Widget content(bool hovered) {
      final (Color bg, Color fg, Color? bd) = switch (widget.kind) {
        SrButtonKind.primary => (
          hovered ? SR.primaryHover : SR.primary,
          SR.onDark,
          SR.primaryHover,
        ),
        SrButtonKind.secondary => (
          hovered ? c.surfaceSubtle : c.surface,
          c.ink2,
          hovered ? c.borderHover : c.border,
        ),
        SrButtonKind.ghost => (
          hovered ? c.dividerSoft : Colors.transparent,
          c.ink2,
          null,
        ),
        SrButtonKind.danger => (
          hovered ? c.redTint : c.surface,
          c.red,
          c.redLine,
        ),
        SrButtonKind.dangerSolid => (c.red, SR.onDark, c.red),
        SrButtonKind.success => (
          hovered ? c.greenDeep : c.greenDark,
          SR.onDark,
          c.greenDeep,
        ),
        SrButtonKind.caution => (
          hovered ? c.amberIcon : c.amberTint,
          c.amberTitle,
          c.amberLine,
        ),
      };

      return AnimatedContainer(
        duration: SR.stateChange,
        curve: SR.easing,
        constraints: BoxConstraints(minHeight: effectiveMinHeight),
        transform: Matrix4.translationValues(0, primary && _pressed ? 1 : 0, 0),
        padding: EdgeInsets.symmetric(
          horizontal: widget.dense ? 11 : 15,
          vertical: widget.minHeight != null || compact
              ? 0
              : (widget.dense ? 6 : 8),
        ),
        decoration: BoxDecoration(
          color: enabled ? bg : c.dividerSoft,
          borderRadius: BorderRadius.circular(SR.rMd),
          border: bd == null
              ? null
              : Border.all(color: enabled ? bd : c.border),
          boxShadow: primary && enabled ? c.cardShadow : null,
        ),
        child: Row(
          mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.icon != null) ...[
              IconTheme.merge(
                data: IconThemeData(color: enabled ? fg : c.muted),
                child: widget.icon!,
              ),
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
                  color: enabled ? fg : c.muted,
                ),
              ),
            ),
            if (widget.trailing != null) ...[
              const SizedBox(width: 8),
              IconTheme.merge(
                data: IconThemeData(color: enabled ? fg : c.muted),
                child: widget.trailing!,
              ),
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
    this.background,
    this.foreground,
    this.hoverForeground = SR.primary,
    this.border,
    this.radius = 9,
    this.shadow,
  });

  final String? glyph;
  final IconData? icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;
  final double fontSize;
  final Color? background;
  final Color? foreground;
  final Color hoverForeground;
  final Color? border;
  final double radius;
  final List<BoxShadow>? shadow;

  @override
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final effectiveSize = compact && size < 44 ? 44.0 : size;
    final c = context.srColors;
    return Tooltip(
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
              width: effectiveSize,
              height: effectiveSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hovered ? c.dividerSoft : (background ?? c.surface),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: border ?? c.border),
                boxShadow: shadow,
              ),
              child: Builder(
                builder: (context) {
                  final tint = onPressed == null
                      ? c.mutedLight
                      : (hovered ? hoverForeground : (foreground ?? c.ink2));
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
}

class DashedBox extends StatelessWidget {
  const DashedBox({
    super.key,
    required this.child,
    this.radius = 11,
    this.color,
    this.background = Colors.transparent,
    this.padding = const EdgeInsets.all(18),
    this.dash = 5,
    this.gap = 4,
    this.stretch = true,
  });

  final Widget child;
  final double radius;
  final Color? color;
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
        color: color ?? context.srColors.dashed,
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              text: text,
              children: [
                if (required)
                  TextSpan(
                    text: ' *',
                    style: sans(11.5, w: 500, color: context.srColors.red),
                  ),
              ],
            ),
            style: sans(11.5, w: 500, color: context.srColors.ink2),
          ),
        ),
        if (meta != null) ...[const SizedBox(width: 8), meta!],
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
    final c = context.srColors;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 5),
            child: Icon(Icons.error_outline_rounded, size: 11, color: c.red),
          ),
          Expanded(
            child: Text(message!, style: sans(11, height: 1.45, color: c.red)),
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
    this.obscureText = false,
    this.textInputAction,
    this.autofillHints,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.textCapitalization = TextCapitalization.none,
    this.prefix,
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
  final bool obscureText;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final bool autocorrect;
  final bool enableSuggestions;
  final TextCapitalization textCapitalization;
  final Widget? prefix;

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
    final c = context.srColors;
    final style = widget.mono
        ? mono(widget.fontSize, color: c.ink)
        : sans(widget.fontSize, height: widget.maxLines == 1 ? null : 1.6);
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final effectivePadding =
        compact &&
            widget.maxLines == 1 &&
            widget.padding ==
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
        ? const EdgeInsets.symmetric(horizontal: 12)
        : widget.padding;
    return AnimatedContainer(
      duration: SR.stateChange,
      constraints: compact && widget.maxLines == 1
          ? const BoxConstraints(minHeight: 46)
          : null,
      padding: effectivePadding,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: widget.hasError
              ? c.red
              : (_focused ? SR.primary : c.borderField),
        ),
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: (widget.hasError ? c.red : SR.primary).withValues(
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
          if (widget.prefix != null) ...[
            widget.prefix!,
            const SizedBox(width: 9),
          ],
          Expanded(
            child: Semantics(
              textField: true,
              label: widget.semanticLabel,
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
                obscureText: widget.obscureText,
                textInputAction: widget.textInputAction,
                autofillHints: widget.autofillHints,
                autocorrect: widget.autocorrect,
                enableSuggestions: widget.enableSuggestions,
                textCapitalization: widget.textCapitalization,
                cursorColor: SR.primary,
                cursorWidth: 1.5,
                style: style,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: widget.placeholder,
                  labelText: null,
                ),
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
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final c = context.srColors;
    return Semantics(
      label: semanticLabel,
      child: Container(
        height: compact ? 44 : 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: hasError ? c.red : c.borderField),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            isDense: true,
            borderRadius: BorderRadius.circular(10),
            dropdownColor: c.surface,
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: c.muted,
            ),
            hint: Text(
              placeholder ?? '',
              style: sans(fontSize, color: c.mutedLight),
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
                          style: mono(9, w: 500, tracking: .04, color: c.amber),
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
}

class SrToggle extends StatefulWidget {
  const SrToggle({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;

  final ValueChanged<bool>? onChanged;
  final String label;

  @override
  State<SrToggle> createState() => _SrToggleState();
}

class _SrToggleState extends State<SrToggle> {
  static const _trackW = 38.0;
  static const _trackH = 22.0;
  static const _thumb = 16.0;
  static const _inset = 3.0;

  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  void _toggle() {
    _node.requestFocus();
    widget.onChanged!(!widget.value);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.space &&
        event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    widget.onChanged!(!widget.value);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final value = widget.value;
    final c = context.srColors;

    return Semantics(
      toggled: value,
      enabled: enabled,
      label: widget.label,
      child: Hoverable(
        enabled: enabled,
        builder: (context, hovered) {
          final track = switch ((enabled, value)) {
            (false, true) => c.primarySoft,
            (false, false) => c.dividerSoft,
            (true, true) => hovered ? SR.primaryHover : SR.primary,
            (true, false) => hovered ? c.borderHover : c.border,
          };

          return Focus(
            focusNode: _node,
            canRequestFocus: enabled,
            onFocusChange: (focused) => setState(() => _focused = focused),
            onKeyEvent: enabled ? _onKey : null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: enabled ? _toggle : null,
              child: SizedBox(
                width: SR.tapTarget,
                height: SR.tapTarget,
                child: Center(
                  child: AnimatedContainer(
                    duration: SR.stateChange,
                    curve: SR.easing,
                    width: _trackW,
                    height: _trackH,
                    decoration: BoxDecoration(
                      color: track,
                      borderRadius: BorderRadius.circular(SR.rFull),
                      boxShadow: _focused && enabled ? SR.focusRing : null,
                    ),
                    child: Stack(
                      children: [
                        AnimatedPositioned(
                          duration: SR.stateChange,
                          curve: SR.easing,
                          top: _inset,
                          left: value ? _trackW - _thumb - _inset : _inset,
                          child: Container(
                            width: _thumb,
                            height: _thumb,
                            decoration: BoxDecoration(
                              color: c.surface,
                              shape: BoxShape.circle,
                              boxShadow: enabled ? c.cardShadow : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
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
    this.valueColor,
    this.valueMono = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool valueMono;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Container(
      color: c.surface,
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
                ? mono(12.5, w: 500, color: valueColor ?? c.ink)
                : sans(12.5, w: 500, color: valueColor ?? c.ink),
          ),
        ],
      ),
    );
  }
}

class SrCellGrid extends StatelessWidget {
  const SrCellGrid({super.key, required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = context.srColors;
      final effectiveColumns = constraints.maxWidth < 240
          ? 1
          : constraints.maxWidth < 520
          ? columns.clamp(1, 2)
          : columns;

      final rows = <Widget>[];

      for (var i = 0; i < children.length; i += effectiveColumns) {
        final slice = children.sublist(
          i,
          (i + effectiveColumns).clamp(0, children.length),
        );

        rows.add(
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < effectiveColumns; c++)
                  Expanded(
                    child: c < slice.length
                        ? slice[c]
                        : ColoredBox(color: colors.surface),
                  ),
              ],
            ),
          ),
        );
      }

      return Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      );
    },
  );
}
