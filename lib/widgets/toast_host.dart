import 'package:flutter/material.dart';

import '../app/app_scope.dart';
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

    return Stack(
      children: [
        Positioned.fill(child: child),
        if (state.toast case final toast?)
          Positioned(
            top: media.padding.top + topInset,
            right: media.padding.right + 22,
            left: isMobile ? media.padding.left + 22 : null,
            child: Align(
              alignment: Alignment.topRight,
              child: IgnorePointer(
                ignoring: toast.action == null,
                child: SrToast(key: const Key('global-toast'), message: toast),
              ),
            ),
          ),
      ],
    );
  }
}
