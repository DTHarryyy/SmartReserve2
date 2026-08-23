import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.crumbs,
    required this.title,
    required this.onOpenProfile,
    required this.avatarInitials,
    this.actions = const [],
    this.chip,
    this.compact = false,
    this.mobile = false,
    this.onMenu,
  });

  final List<String> crumbs;
  final String title;
  final VoidCallback onOpenProfile;
  final String avatarInitials;

  final List<Widget> actions;

  final Widget? chip;
  final bool compact;
  final bool mobile;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: compact ? SR.space16 : SR.space24,
      vertical: compact ? SR.space8 : SR.space12,
    ),
    decoration: BoxDecoration(
      color: SR.surface,
      border: Border(bottom: BorderSide(color: SR.border)),
    ),
    child: Row(
      children: [
        if (onMenu != null) ...[
          SrIconButton(
            icon: Icons.menu_rounded,
            tooltip: 'Sections',
            size: SR.controlMd,
            fontSize: 15,
            onPressed: onMenu,
          ),
          const SizedBox(width: SR.space12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!compact) ...[
                _Breadcrumbs(crumbs: crumbs),
                const SizedBox(height: SR.space2),
              ],
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: compact ? SrType.subhead() : SrType.heading(),
              ),
            ],
          ),
        ),
        if (chip != null && !compact) ...[
          const SizedBox(width: SR.space12),
          chip!,
        ],
        if (!compact) ...[
          const SizedBox(width: SR.space8),
          _Avatar(initials: avatarInitials, onTap: onOpenProfile),
        ],
        for (final action in actions) ...[
          const SizedBox(width: SR.space8),
          action,
        ],
      ],
    ),
  );
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.crumbs});

  final List<String> crumbs;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 0; i < crumbs.length; i++) ...[
        if (i > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: SR.space2),
            child: Icon(
              Icons.chevron_right_rounded,
              size: SR.iconSm,
              color: SR.mutedLight,
            ),
          ),
        Flexible(
          child: Text(
            crumbs[i],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: i == crumbs.length - 1
                ? SrType.caption(w: 500, color: SR.ink3)
                : SrType.caption(),
          ),
        ),
      ],
    ],
  );
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initials, required this.onTap});

  final String initials;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Your profile',
    child: Semantics(
      button: true,
      label: 'Your profile',
      child: Hoverable(
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: SR.stateChange,
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: SR.primaryTint,
              shape: BoxShape.circle,
              border: Border.all(
                color: hovered ? SR.primarySoft : SR.primaryLine,
              ),
            ),
            child: Text(
              initials,
              style: mono(11, w: 600, color: SR.primaryDeep),
            ),
          ),
        ),
      ),
    ),
  );
}

class HeaderChip extends StatelessWidget {
  const HeaderChip({super.key, required this.label, this.dot = SR.green});

  final String label;
  final Color dot;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: SR.space12,
      vertical: SR.space6,
    ),
    decoration: BoxDecoration(
      color: SR.surfaceSubtle,
      borderRadius: BorderRadius.circular(SR.rFull),
      border: Border.all(color: SR.border),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: SR.space6,
          height: SR.space6,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: SR.space6),
        Text(label, style: SrType.caption(w: 500, color: SR.ink3)),
      ],
    ),
  );
}
