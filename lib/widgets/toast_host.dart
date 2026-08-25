import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../app/sr_toast_controller.dart';
import '../theme/sr_tokens.dart';
import 'notices.dart';

class AppToastHost extends StatelessWidget {
  const AppToastHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: child),
      // The toast layer gets its own Overlay. AppToastHost is mounted from
      // MaterialApp.builder, wrapping the Navigator's child — which makes
      // this subtree an *ancestor* of the Navigator, not a descendant, so it
      // sits outside the Overlay the Navigator owns. Any Overlay-reading
      // widget in the toast tree (Tooltip, etc.) would throw "No Overlay
      // widget found." without this.
      //
      // OverlayEntry.builder only runs once, from `initialEntries` — a
      // rebuild of AppToastHost hands the Overlay a *new* OverlayEntry, but
      // OverlayState silently ignores it after initState, so the content
      // must read AppScope/MediaQuery itself (via its own BuildContext,
      // which does live in the tree and does react to InheritedWidget
      // changes) rather than capturing them from this outer build().
      Positioned.fill(
        child: Overlay(
          initialEntries: [OverlayEntry(builder: (_) => const _ToastLayer())],
        ),
      ),
    ],
  );
}

class _ToastLayer extends StatelessWidget {
  const _ToastLayer();

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
        return Positioned(
          top: media.padding.top + topInset,
          left: media.padding.left + horizontalInset,
          right: media.padding.right + horizontalInset,
          // Clicks fall through to the app below everywhere the toast isn't
          // painted; only intercept pointer events while a toast is showing.
          // (IgnorePointer must be *inside* Positioned — Positioned is a
          // ParentDataWidget<Stack> and has to be the outermost wrapper for
          // the Overlay's Theatre to see this branch as positioned at all.)
          child: IgnorePointer(
            ignoring: active == null,
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
                            CurvedAnimation(parent: animation, curve: SR.easing),
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
