import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.crumbs,
    required this.title,
    required this.onToggleStates,
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
  final VoidCallback onToggleStates;
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
      horizontal: compact ? 16 : 24,
      vertical: compact ? 10 : 12,
    ),
    decoration: const BoxDecoration(
      color: SR.bg,
      border: Border(bottom: BorderSide(color: SR.border)),
    ),
    child: Row(
      children: [
        if (onMenu != null) ...[
          SrIconButton(
            glyph: '☰',
            tooltip: 'Sections',
            size: 36,
            fontSize: 13,
            onPressed: onMenu,
          ),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!compact) ...[
                Row(
                  children: [
                    for (var i = 0; i < crumbs.length; i++) ...[
                      if (i > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 7),
                          child: Text(
                            '/',
                            style: sans(11, color: SR.mutedLight),
                          ),
                        ),
                      Flexible(
                        child: Text(
                          crumbs[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: i == crumbs.length - 1
                              ? sans(11, w: 500)
                              : sans(11, color: SR.ink4),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
              ],
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(
                  compact ? 15 : 17,
                  w: 600,
                  height: 1.25,
                  tracking: -.015,
                ),
              ),
            ],
          ),
        ),
        if (chip != null && !compact) ...[const SizedBox(width: 14), chip!],
        if (!compact) ...[
          const SizedBox(width: 12),
          SrButton(
            label: 'States',
            dense: true,
            fontSize: 12,
            onPressed: onToggleStates,
          ),
        ],
        if (!compact) ...[
          const SizedBox(width: 8),
          _Avatar(initials: avatarInitials, onTap: onOpenProfile),
        ],
        for (final action in actions) ...[const SizedBox(width: 8), action],
      ],
    ),
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
              color: hovered ? SR.blueTint2 : SR.surface,
              shape: BoxShape.circle,
              border: Border.all(color: hovered ? SR.blueSoft : SR.border),
            ),
            child: Text(initials, style: mono(11, w: 600, color: SR.blueDark)),
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
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: SR.border),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: sans(11, color: SR.ink4)),
      ],
    ),
  );
}
