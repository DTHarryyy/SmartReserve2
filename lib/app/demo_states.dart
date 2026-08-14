import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import '../widgets/sr_controls.dart';
import 'app_state.dart';
import 'app_view.dart';

class DemoState {
  const DemoState(this.label, this.apply);

  final String label;
  final void Function(AppState state) apply;
}

const demoStates = <DemoState>[
  DemoState('Add facility · blank', _addBlank),
  DemoState('Add facility · unsaved draft found', _addDraft),
  DemoState('Add facility · map tiles offline', _addOffline),
  DemoState('Reservations queue', _reservations),
  DemoState('Verifications queue', _verifications),
  DemoState('Users', _users),
  DemoState('Audit log', _audit),
  DemoState('Reports', _reports),
  DemoState('Design notes', _notes),
  DemoState('Student app', _student),
  DemoState('Onboarding', _auth),
];

void _addBlank(AppState s) {
  s.setDemo(mapOffline: false, draftBanner: false);
  s.goTo(AppView.addFacility);
}

void _addDraft(AppState s) {
  s.setDemo(draftBanner: true);
  s.goTo(AppView.addFacility);
}

void _addOffline(AppState s) {
  s.setDemo(mapOffline: true);
  s.goTo(AppView.addFacility);
}

void _reservations(AppState s) => s.goTo(AppView.reservations);
void _verifications(AppState s) => s.goTo(AppView.verifications);
void _users(AppState s) => s.goTo(AppView.users);
void _audit(AppState s) => s.goTo(AppView.audit);
void _reports(AppState s) => s.goTo(AppView.reports);
void _notes(AppState s) => s.goTo(AppView.notes);
void _student(AppState s) => s.goTo(AppView.userApp);
void _auth(AppState s) => s.goTo(AppView.auth);

class DemoStatesMenu extends StatelessWidget {
  const DemoStatesMenu({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: SR.stateChange,
    curve: SR.easing,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.scale(scale: .96 + t * .04, child: child),
    ),
    child: Container(
      width: 250,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SR.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2910141A),
            blurRadius: 40,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Text(
              'PROTOTYPE STATES',
              style: mono(10, w: 500, tracking: .04, color: SR.muted),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(context).height - 110).clamp(
                160.0,
                420.0,
              ),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final demo in demoStates)
                    Hoverable(
                      builder: (context, hovered) => GestureDetector(
                        onTap: () {
                          state.statesOpen = false;
                          demo.apply(state);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: hovered
                                ? SR.dividerSoft
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            demo.label,
                            style: sans(12, color: SR.ink2),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
