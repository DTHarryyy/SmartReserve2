import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

/// Shared dialog surface that becomes a safe, full-screen page on phones.
class SrAdaptiveDialog extends StatelessWidget {
  const SrAdaptiveDialog({
    super.key,
    required this.child,
    required this.maxWidth,
    required this.maxHeight,
    this.padding = EdgeInsets.zero,
    this.clipBehavior = Clip.antiAlias,
    this.fullScreenOnCompact = true,
  });

  final Widget child;
  final double maxWidth;
  final double maxHeight;
  final EdgeInsetsGeometry padding;
  final Clip clipBehavior;
  final bool fullScreenOnCompact;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final compact = SR.isCompact(media.size.width) && fullScreenOnCompact;
    final medium = media.size.width < SR.desktopMin;
    final inset = compact ? EdgeInsets.zero : EdgeInsets.all(medium ? 16 : 24);
    final surface = Container(
      width: compact ? media.size.width : null,
      height: compact ? media.size.height : null,
      constraints: BoxConstraints(
        maxWidth: compact ? media.size.width : maxWidth,
        maxHeight: compact ? media.size.height : maxHeight,
      ),
      padding: padding,
      clipBehavior: clipBehavior,
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: compact ? BorderRadius.zero : BorderRadius.circular(14),
        boxShadow: compact ? null : SR.dialogShadow,
      ),
      child: compact ? SafeArea(child: child) : child,
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: inset,
      child: surface,
    );
  }
}

/// Confirmation surface with safe compact sizing and actions that never rely
/// on a single narrow row.
class SrConfirmDialog extends StatelessWidget {
  const SrConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onCancel,
    this.cancelLabel = 'Cancel',
    this.destructive = false,
  });

  final String title;
  final Widget content;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final String cancelLabel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final cancel = OutlinedButton(
      onPressed: onCancel,
      style: OutlinedButton.styleFrom(minimumSize: const Size(44, 44)),
      child: Text(cancelLabel),
    );
    final confirm = FilledButton(
      onPressed: onConfirm,
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 44),
        backgroundColor: destructive ? SR.red : SR.blue,
      ),
      child: Text(confirmLabel),
    );
    return SrAdaptiveDialog(
      maxWidth: 480,
      maxHeight: 380,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 16 : 22,
              compact ? 8 : 18,
              compact ? 6 : 10,
              compact ? 8 : 12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'IBM Plex Sans',
                      fontSize: compact ? 18 : 19,
                      fontWeight: FontWeight.w600,
                      color: SR.ink,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  constraints: const BoxConstraints.tightFor(
                    width: 44,
                    height: 44,
                  ),
                  onPressed: onCancel,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: SR.border),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(compact ? 16 : 22),
              child: DefaultTextStyle(
                style: const TextStyle(
                  fontFamily: 'IBM Plex Sans',
                  fontSize: 13,
                  height: 1.55,
                  color: SR.ink3,
                ),
                child: content,
              ),
            ),
          ),
          const Divider(height: 1, color: SR.border),
          Padding(
            padding: EdgeInsets.all(compact ? 16 : 18),
            child: compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [confirm, const SizedBox(height: 8), cancel],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [cancel, const SizedBox(width: 8), confirm],
                  ),
          ),
        ],
      ),
    );
  }
}
