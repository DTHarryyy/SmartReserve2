import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../app/sr_toast_controller.dart';
import '../theme/sr_tokens.dart';
import 'notices.dart';

class AppToastHost extends StatelessWidget {
  const AppToastHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final media = MediaQuery.of(context);
    final width = media.size.width;
    final isDesktop = width >= SR.desktopMin;
    final isMobile = width < SR.tabletMin;
    final topInset = state.view.usesAdminChrome
        ? (isDesktop ? 68.0 : 72.0)
        : 22.0;

    final horizontalInset = isMobile ? 16.0 : 24.0;
    return AnimatedBuilder(
      animation: state.toasts,
      builder: (context, _) {
        final active = state.toasts.active;
        return Stack(
          children: [
            Positioned.fill(child: child),
            Positioned(
              top: media.padding.top + topInset,
              left: media.padding.left + horizontalInset,
              right: media.padding.right + horizontalInset,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: AnimatedSwitcher(
                    duration: SR.entrance,
                    reverseDuration: SR.entrance,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position:
                            Tween<Offset>(
                              begin: const Offset(0, -.12),
                              end: Offset.zero,
                            ).animate(
                              CurvedAnimation(
                                parent: animation,
                                curve: SR.easing,
                              ),
                            ),
                        child: child,
                      ),
                    ),
                    child: active == null
                        ? const SizedBox.shrink(key: ValueKey('toast-empty'))
                        : _ToastSlot(
                            key: ValueKey(active.id),
                            active: active,
                            controller: state.toasts,
                          ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ToastSlot extends StatelessWidget {
  const _ToastSlot({super.key, required this.active, required this.controller});

  final ActiveToast active;
  final SrToastController controller;

  @override
  Widget build(BuildContext context) => SrToast(
    key: const Key('global-toast'),
    message: active.message,
    onDismiss: () => controller.dismiss(id: active.id),
    onAction: controller.invokeAction,
  );
}
