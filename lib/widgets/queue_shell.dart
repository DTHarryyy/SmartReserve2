import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/sr_tokens.dart';
import 'notices.dart';
import 'sr_controls.dart';

class QueueShell extends StatelessWidget {
  const QueueShell({
    super.key,
    required this.list,
    required this.panel,
    required this.stacked,
    required this.panelOpen,
    required this.onClosePanel,
    this.listPadding = const EdgeInsets.fromLTRB(20, 16, 20, 32),
    this.panelPadding = const EdgeInsets.fromLTRB(16, 16, 20, 24),
  });

  final Widget list;

  final Widget? panel;

  final bool stacked;
  final bool panelOpen;
  final VoidCallback onClosePanel;

  final EdgeInsets listPadding;
  final EdgeInsets panelPadding;

  @override
  Widget build(BuildContext context) {
    final listPane = Scrollbar(
      child: SingleChildScrollView(padding: listPadding, child: list),
    );

    if (stacked) {
      return Stack(
        children: [
          Positioned.fill(child: listPane),
          if (panelOpen && panel != null) ...[
            Positioned.fill(
              child: GestureDetector(
                onTap: onClosePanel,
                child: const ColoredBox(color: Color(0x6B10141A)),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              top: 40,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
                child: ColoredBox(
                  color: SR.bg,
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: const BoxDecoration(
                          color: SR.bg,
                          border: Border(bottom: BorderSide(color: SR.border)),
                        ),
                        child: Row(
                          children: [
                            SrIconButton(
                              glyph: '←',
                              tooltip: 'Back to the queue',
                              size: 36,
                              fontSize: 14,
                              onPressed: onClosePanel,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Decision',
                              style: sans(13, w: 600, tracking: -.01),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Scrollbar(
                          child: SingleChildScrollView(
                            padding: panelPadding,
                            child: panel!,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 4,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: SR.border)),
            ),
            child: listPane,
          ),
        ),
        Expanded(
          flex: 5,
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: panelPadding,
              child: panel ?? const _NothingSelected(),
            ),
          ),
        ),
      ],
    );
  }
}

class _NothingSelected extends StatelessWidget {
  const _NothingSelected();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 260,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Nothing selected', style: sans(13.5, w: 600)),
            const SizedBox(height: 5),
            Text(
              'Pick an item to see its checks and the decision controls.',
              textAlign: TextAlign.center,
              style: sans(12, height: 1.6, color: SR.ink4),
            ),
          ],
        ),
      ),
    ),
  );
}

class QueueTab extends StatelessWidget {
  const QueueTab({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? SR.ink : SR.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? SR.ink : (hovered ? SR.borderHover : SR.border),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: sans(12, w: 500, color: selected ? SR.surface : SR.ink3),
              ),
              const SizedBox(width: 7),
              Text(
                '$count',
                style: mono(
                  10.5,
                  w: 500,
                  color: selected
                      ? SR.surface.withValues(alpha: .65)
                      : SR.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class BulkBar extends StatelessWidget {
  const BulkBar({
    super.key,
    required this.label,
    required this.actionLabel,
    required this.onAction,
    required this.onClear,
    this.blockedNote,
  });

  final String label;
  final String actionLabel;

  final VoidCallback? onAction;
  final VoidCallback onClear;
  final String? blockedNote;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: SR.ink,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: sans(12, w: 500, color: SR.surface)),
              if (blockedNote != null) ...[
                const SizedBox(height: 2),
                Text(
                  blockedNote!,
                  style: sans(
                    10.5,
                    height: 1.4,
                    color: const Color(0x99FFFFFF),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        if (onAction != null)
          DarkBarButton(label: actionLabel, onPressed: onAction!, solid: true)
        else
          Opacity(
            opacity: .4,
            child: DarkBarButton(
              label: actionLabel,
              onPressed: () {},
              solid: true,
            ),
          ),
        const SizedBox(width: 8),
        DarkBarButton(label: 'Clear', onPressed: onClear),
      ],
    ),
  );
}

class SelectBox extends StatelessWidget {
  const SelectBox({
    super.key,
    required this.selected,
    required this.onTap,
    required this.semanticLabel,
  });

  final bool selected;
  final ValueChanged<bool> onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    checked: selected,
    label: semanticLabel,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: () => onTap(HardwareKeyboard.instance.isShiftPressed),
        child: Container(
          width: 17,
          height: 17,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? SR.blue : SR.surface,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: selected
                  ? SR.blue
                  : (hovered ? SR.blueSoft : SR.borderField),
            ),
          ),
          child: selected
              ? const Icon(Icons.check_rounded, size: 11, color: SR.surface)
              : null,
        ),
      ),
    ),
  );
}
