import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_view.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final admin = state.currentAdmin;
    final width = MediaQuery.sizeOf(context).width;

    return SrScrollView(
      padding: SR.pageInsets(width, bottom: SR.space32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SrButton(
                  label: 'Back',
                  icon: Icon(
                    Icons.arrow_back_rounded,
                    size: SR.iconSm,
                    color: context.srColors.ink3,
                  ),
                  kind: SrButtonKind.ghost,
                  dense: true,
                  fontSize: 11.5,
                  onPressed: state.leaveProfile,
                ),
              ),
              const SizedBox(height: SR.space12),
              SrCard(
                padding: EdgeInsets.all(context.isCompact ? 16 : SR.space20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        SrAvatar(initials: admin.initials, size: 46),
                        const SizedBox(width: SR.space12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(admin.name, style: SrType.heading()),
                              const SizedBox(height: SR.space2),
                              Text(
                                admin.email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: SrType.code(
                                  color: context.srColors.muted,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(admin.unit, style: SrType.caption()),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: SR.space16),
                    SrCellGrid(
                      columns: 1,
                      children: [
                        SrKeyCell(label: 'ROLE', value: admin.role.label),
                        SrKeyCell(
                          label: 'EMPLOYEE NUMBER',
                          value: admin.idNumber,
                          valueMono: true,
                        ),
                        SrKeyCell(label: 'JOINED', value: admin.joined),
                        SrKeyCell(
                          label: 'SESSION',
                          value: 'Admin sessions expire after 12 hours',
                        ),
                      ],
                    ),
                    const SizedBox(height: SR.space12 + 2),
                    _InfoBanner(
                      icon: Icons.shield_outlined,
                      tone: SrTone.info,
                      text: admin.role.privileges,
                    ),
                    const SizedBox(height: SR.space8),
                    _InfoBanner(
                      icon: Icons.info_outline_rounded,
                      tone: SrTone.neutral,
                      text:
                          'Nobody can change their own role. To alter '
                          'yours, ask another internal admin from the '
                          'Users page.',
                    ),
                    const SizedBox(height: SR.space12 + 2),
                    Text('Appearance', style: SrType.label()),
                    const SizedBox(height: SR.space8),
                    SrThemeSelector(
                      value: state.themePreference,
                      compact: context.isCompact,
                      onChanged: state.setThemePreference,
                    ),
                    const SizedBox(height: SR.space12 + 2),
                    SrButton(
                      label: 'Open my record in Users',
                      icon: Icon(
                        Icons.badge_outlined,
                        size: SR.iconSm,
                        color: context.srColors.ink3,
                      ),
                      expand: true,
                      minHeight: 42,
                      fontSize: 12.5,
                      onPressed: () => state.goTo(AppView.users),
                    ),
                    const SizedBox(height: SR.space8),
                    SrButton(
                      label: 'Sign out',
                      icon: Icon(
                        Icons.logout_rounded,
                        size: SR.iconSm,
                        color: context.srColors.red,
                      ),
                      kind: SrButtonKind.danger,
                      expand: true,
                      minHeight: 42,
                      fontSize: 12.5,
                      onPressed: () => state.signOut(),
                    ),
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

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.icon,
    required this.tone,
    required this.text,
  });

  final IconData icon;
  final SrTone tone;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: SR.space12 + 1,
      vertical: SR.space12,
    ),
    decoration: BoxDecoration(
      color: tone.tint,
      borderRadius: BorderRadius.circular(SR.rMd - 2),
      border: Border.all(color: tone.line),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: SR.iconSm, color: tone.ink),
        const SizedBox(width: SR.space8),
        Expanded(
          child: Text(text, style: SrType.bodySm(color: tone.ink)),
        ),
      ],
    ),
  );
}
