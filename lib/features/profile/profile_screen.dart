import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_view.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/sr_controls.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final admin = state.currentAdmin;
    final width = MediaQuery.sizeOf(context).width;

    return Scrollbar(
      child: SingleChildScrollView(
        padding: SR.pageInsets(width, bottom: 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SrButton(
                    label: '← Back',
                    dense: true,
                    fontSize: 11.5,
                    onPressed: state.leaveProfile,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.all(SR.isCompact(width) ? 16 : 20),
                  decoration: BoxDecoration(
                    color: SR.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: SR.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Initials(
                            text: admin.initials,
                            size: 46,
                            fontSize: 14,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  admin.name,
                                  style: sans(16, w: 600, tracking: -.015),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  admin.email,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: mono(11, color: SR.muted),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  admin.unit,
                                  style: sans(11, color: SR.ink4),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
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
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: SR.blueTint2,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: SR.blueLine),
                        ),
                        child: Text(
                          admin.role.privileges,
                          style: sans(11.5, height: 1.6, color: SR.blueInk),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: SR.surfaceSubtle,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: SR.hairline),
                        ),
                        child: Text(
                          'Nobody can change their own role. To alter yours, '
                          'ask another internal admin from the Users page.',
                          style: sans(11.5, height: 1.6, color: SR.ink4),
                        ),
                      ),
                      const SizedBox(height: 14),
                      SrButton(
                        label: 'Open my record in Users',
                        expand: true,
                        minHeight: 42,
                        fontSize: 12.5,
                        onPressed: () => state.goTo(AppView.users),
                      ),
                      const SizedBox(height: 8),
                      SrButton(
                        label: 'Sign out',
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
      ),
    );
  }
}
