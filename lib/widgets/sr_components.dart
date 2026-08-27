import 'package:flutter/material.dart';

import '../theme/sr_theme.dart';
import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

enum SrCardLevel { flat, sunken, tinted, raised }

class SrCard extends StatelessWidget {
  const SrCard({
    super.key,
    required this.child,
    this.level = SrCardLevel.flat,
    this.padding = const EdgeInsets.all(SR.space16),
    this.margin,
    this.radius = SR.rLg,
    this.onTap,
  });

  const SrCard.bare({
    super.key,
    required this.child,
    this.level = SrCardLevel.flat,
    this.margin,
    this.radius = SR.rLg,
    this.onTap,
  }) : padding = EdgeInsets.zero;

  final Widget child;
  final SrCardLevel level;
  final EdgeInsets padding;
  final EdgeInsets? margin;
  final double radius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final (Color bg, Color? border) = switch (level) {
      SrCardLevel.flat => (c.surface, c.border),
      SrCardLevel.sunken => (c.surfaceSubtle, null),
      SrCardLevel.tinted => (c.primaryTint2, c.primaryLine),
      SrCardLevel.raised => (c.surface, null),
    };

    Widget content = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: border == null ? null : Border.all(color: border),
        boxShadow: level == SrCardLevel.raised ? c.floatShadow : null,
      ),
      child: child,
    );

    if (onTap == null) return content;
    return Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          margin: margin,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: hovered && level == SrCardLevel.raised
                ? c.popoverShadow
                : null,
          ),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: hovered && level != SrCardLevel.raised
                  ? c.surfaceSubtle
                  : bg,
              borderRadius: BorderRadius.circular(radius),
              border: border == null
                  ? null
                  : Border.all(color: hovered ? c.borderHover : border),
              boxShadow: level == SrCardLevel.raised ? c.floatShadow : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class SrPageHeader extends StatelessWidget {
  const SrPageHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.description,
    this.actions = const [],
  });

  final String? eyebrow;
  final String title;
  final String? description;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (eyebrow case final eyebrow?) ...[
              Text(
                eyebrow,
                style: SrType.overline(color: context.srColors.primaryDeep),
              ),
              const SizedBox(height: SR.space4),
            ],
            Text(title, style: SrType.title()),
            if (description case final description?) ...[
              const SizedBox(height: SR.space4),
              Text(description, style: SrType.bodySm()),
            ],
          ],
        ),
      ),
      if (actions.isNotEmpty) ...[
        const SizedBox(width: SR.space12),
        Wrap(spacing: SR.space8, runSpacing: SR.space8, children: actions),
      ],
    ],
  );
}

class SrSectionHeader extends StatelessWidget {
  const SrSectionHeader({
    super.key,
    required this.title,
    this.description,
    this.action,
    this.icon,
  });

  final String title;
  final String? description;
  final Widget? action;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: SR.space12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: SR.iconMd, color: context.srColors.ink3),
          const SizedBox(width: SR.space8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: SrType.subhead()),
              if (description case final description?) ...[
                const SizedBox(height: SR.space2),
                Text(description, style: SrType.caption()),
              ],
            ],
          ),
        ),
        ?action,
      ],
    ),
  );
}

class SrStatusChip extends StatelessWidget {
  const SrStatusChip({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
    this.dot = false,
    this.dense = false,
  });

  final String label;
  final SrTone tone;
  final IconData? icon;

  final bool dot;
  final bool dense;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: dense ? SR.space6 : SR.space8,
      vertical: dense ? 2 : 3,
    ),
    decoration: BoxDecoration(
      color: tone.tint,
      borderRadius: BorderRadius.circular(SR.rFull),
      border: Border.all(color: tone.line),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot) ...[
          Container(
            width: SR.space6,
            height: SR.space6,
            decoration: BoxDecoration(
              color: tone.solid,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: SR.space6),
        ] else if (icon != null) ...[
          Icon(icon, size: 12, color: tone.ink),
          const SizedBox(width: SR.space4),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SrType.caption(w: 600, color: tone.ink),
          ),
        ),
      ],
    ),
  );
}

@immutable
class SrTabItem {
  const SrTabItem({required this.label, this.icon, this.count});

  final String label;
  final IconData? icon;
  final int? count;
}

class SrTabs extends StatelessWidget {
  const SrTabs({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    this.scrollable = false,
  });

  final List<SrTabItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final row = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(SR.rSm + 2),
      ),
      child: Row(
        mainAxisSize: scrollable ? MainAxisSize.min : MainAxisSize.max,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            scrollable
                ? _SrTab(
                    item: items[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelect(i),
                  )
                : Expanded(
                    child: _SrTab(
                      item: items[i],
                      selected: i == selectedIndex,
                      onTap: () => onSelect(i),
                    ),
                  ),
          ],
        ],
      ),
    );
    return scrollable
        ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: row)
        : row;
  }
}

class _SrTab extends StatelessWidget {
  const _SrTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final SrTabItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          curve: SR.easing,
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: SR.space12),
          decoration: BoxDecoration(
            color: selected
                ? c.surface
                : (hovered
                      ? c.surface.withValues(alpha: .5)
                      : Colors.transparent),
            borderRadius: BorderRadius.circular(SR.rXs),
            boxShadow: selected ? c.cardShadow : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.icon != null) ...[
                Icon(
                  item.icon,
                  size: SR.iconSm,
                  color: selected ? c.primaryDeep : c.ink4,
                ),
                const SizedBox(width: SR.space6),
              ],
              Flexible(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(
                    12.5,
                    w: selected ? 600 : 500,
                    color: selected ? c.primaryDeep : c.ink3,
                  ),
                ),
              ),
              if (item.count case final count?) ...[
                const SizedBox(width: SR.space6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? c.primaryTint : c.divider,
                    borderRadius: BorderRadius.circular(SR.rFull),
                  ),
                  child: Text(
                    '$count',
                    style: mono(
                      10,
                      w: 600,
                      color: selected ? c.primaryDeep : c.ink4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SrStat extends StatelessWidget {
  const SrStat({
    super.key,
    required this.label,
    required this.value,
    this.tone = SrTone.neutral,
    this.trend,
    this.trendUp,
  });

  final String label;
  final String value;
  final SrTone tone;

  final String? trend;
  final bool? trendUp;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: SrType.overline()),
        const SizedBox(height: SR.space6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: SrType.display(
                color: tone == SrTone.neutral ? c.ink : tone.ink,
              ),
            ),
            if (trend case final trend?) ...[
              const SizedBox(width: SR.space8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    trendUp == false
                        ? Icons.trending_down_rounded
                        : Icons.trending_up_rounded,
                    size: SR.iconSm,
                    color: trendUp == false ? c.red : SR.green,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    trend,
                    style: SrType.bodySm(
                      w: 600,
                      color: trendUp == false ? c.red : SR.green,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class SrSearchField extends StatelessWidget {
  const SrSearchField({
    super.key,
    required this.controller,
    this.placeholder = 'Search',
    this.onChanged,
    this.focusNode,
    this.semanticLabel,
  });

  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => SrTextField(
    controller: controller,
    focusNode: focusNode,
    placeholder: placeholder,
    onChanged: onChanged,
    semanticLabel: semanticLabel ?? placeholder,
    prefix: Icon(
      Icons.search_rounded,
      size: SR.iconMd,
      color: context.srColors.muted,
    ),
    suffix: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => controller.text.isEmpty
          ? const SizedBox.shrink()
          : SrIconButton(
              icon: Icons.close_rounded,
              tooltip: 'Clear',
              size: 28,
              fontSize: 11,
              background: Colors.transparent,
              border: null,
              onPressed: () {
                controller.clear();
                onChanged?.call('');
              },
            ),
    ),
  );
}

class SrFactChip extends StatelessWidget {
  const SrFactChip({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SR.space8,
        vertical: SR.space6,
      ),
      decoration: BoxDecoration(
        color: c.surfaceSubtle,
        borderRadius: BorderRadius.circular(SR.rSm),
        border: Border.all(color: c.hairline),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label: ', style: SrType.caption()),
            TextSpan(
              text: value,
              style: SrType.caption(w: 500, color: c.ink3),
            ),
          ],
        ),
      ),
    );
  }
}

class SrLoadingState extends StatelessWidget {
  const SrLoadingState({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: SR.space48),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        if (message case final message?) ...[
          const SizedBox(height: SR.space12),
          Text(message, style: SrType.bodySm()),
        ],
      ],
    ),
  );
}

class SrAvatar extends StatelessWidget {
  const SrAvatar({
    super.key,
    required this.initials,
    this.size = 40,
    this.tone = SrTone.brand,
  });

  final String initials;
  final double size;
  final SrTone tone;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: tone.tint, shape: BoxShape.circle),
    child: Text(initials, style: mono(size * .30, w: 600, color: tone.ink)),
  );
}

class SrListRow extends StatelessWidget {
  const SrListRow({
    super.key,
    required this.label,
    this.value,
    this.valueMono = false,
    this.icon,
    this.trailing,
    this.onTap,
    this.tone,
  });

  final String label;
  final String? value;
  final bool valueMono;
  final IconData? icon;

  final Widget? trailing;
  final VoidCallback? onTap;

  final SrTone? tone;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final labelStyle = SrType.body(w: 500, color: tone?.ink ?? c.ink);

    Widget content = LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < SR.contentTiny;
        final valueText = value == null
            ? null
            : Text(
                value!,
                maxLines: stack ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                textAlign: stack ? TextAlign.start : TextAlign.end,
                style: valueMono
                    ? SrType.code(color: c.ink4)
                    : SrType.bodySm(color: c.ink4),
              );
        final chevron =
            trailing ??
            (onTap == null
                ? null
                : Icon(
                    Icons.chevron_right_rounded,
                    size: SR.iconMd,
                    color: c.muted,
                  ));

        return Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: SR.iconMd, color: tone?.ink ?? c.ink3),
              const SizedBox(width: SR.space12),
            ],
            Expanded(
              child: stack
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label, style: labelStyle),
                        if (valueText != null) ...[
                          const SizedBox(height: SR.space2),
                          valueText,
                        ],
                      ],
                    )
                  : Row(
                      children: [
                        Text(label, style: labelStyle),
                        if (valueText != null) ...[
                          const SizedBox(width: SR.space12),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: valueText,
                            ),
                          ),
                        ] else
                          const Spacer(),
                      ],
                    ),
            ),
            if (chevron != null) ...[const SizedBox(width: SR.space8), chevron],
          ],
        );
      },
    );

    content = Container(
      constraints: const BoxConstraints(minHeight: SR.tapTarget),
      padding: const EdgeInsets.symmetric(
        horizontal: SR.space16,
        vertical: SR.space12,
      ),
      alignment: Alignment.centerLeft,
      child: content,
    );

    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: label,
      child: Hoverable(
        builder: (context, hovered) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: SR.stateChange,
            color: hovered ? c.surfaceSubtle : c.surface,
            child: content,
          ),
        ),
      ),
    );
  }
}

class SrListGroup extends StatelessWidget {
  const SrListGroup({
    super.key,
    required this.children,
    this.title,
    this.footnote,
  });

  final List<Widget> children;
  final String? title;
  final String? footnote;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: SR.space20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title case final title?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SR.space4,
              0,
              SR.space4,
              SR.space8,
            ),
            child: Text(title, style: SrType.overline()),
          ),
        SrCard.bare(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(SR.rMd),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: SR.space16,
                      color: context.srColors.hairline,
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ),
        if (footnote case final footnote?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SR.space4,
              SR.space8,
              SR.space4,
              0,
            ),
            child: Text(footnote, style: SrType.caption()),
          ),
      ],
    ),
  );
}

class SrPasswordField extends StatefulWidget {
  const SrPasswordField({
    super.key,
    required this.controller,
    this.placeholder,
    this.semanticLabel = 'Password',
    this.hasError = false,
    this.newPassword = false,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? placeholder;
  final String semanticLabel;
  final bool hasError;

  final bool newPassword;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<SrPasswordField> createState() => _SrPasswordFieldState();
}

class _SrPasswordFieldState extends State<SrPasswordField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final c = context.srColors;
    return SrTextField(
      controller: widget.controller,
      placeholder:
          widget.placeholder ??
          (widget.newPassword
              ? 'Create a passphrase of 10+ characters'
              : 'Enter your password'),
      semanticLabel: widget.semanticLabel,
      hasError: widget.hasError,
      obscureText: _hidden,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: [
        widget.newPassword ? AutofillHints.newPassword : AutofillHints.password,
      ],
      textInputAction: widget.onSubmitted == null
          ? TextInputAction.next
          : TextInputAction.done,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      suffix: Semantics(
        button: true,
        label: _hidden ? 'Show password' : 'Hide password',
        child: SizedBox.square(
          dimension: compact ? SR.tapTarget : 20,
          child: IconButton(
            tooltip: _hidden ? 'Show password' : 'Hide password',
            constraints: BoxConstraints.tightFor(
              width: compact ? SR.tapTarget : 20,
              height: compact ? SR.tapTarget : 20,
            ),
            padding: EdgeInsets.zero,
            icon: Icon(
              _hidden
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 19,
              color: c.ink4,
            ),
            onPressed: () => setState(() => _hidden = !_hidden),
          ),
        ),
      ),
    );
  }
}

class SrErrorState extends StatelessWidget {
  const SrErrorState({
    super.key,
    required this.message,
    this.title = 'Something went wrong',
    this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      vertical: SR.space48,
      horizontal: SR.space24,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.srColors.redTint,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.error_outline_rounded,
            color: context.srColors.red,
            size: 22,
          ),
        ),
        const SizedBox(height: SR.space16),
        Text(title, style: SrType.subhead()),
        const SizedBox(height: SR.space6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: SrType.bodySm(),
          ),
        ),
        if (onRetry != null) ...[
          const SizedBox(height: SR.space16),
          SrButton(label: 'Try again', onPressed: onRetry),
        ],
      ],
    ),
  );
}
