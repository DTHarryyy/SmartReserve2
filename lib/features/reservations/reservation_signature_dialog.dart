import 'package:flutter/material.dart';

import '../../backend/supabase_service.dart' show ReservationUpload;
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/signature_pad.dart';
import '../../widgets/sr_controls.dart';

/// Collects the requester's own e-signature by drawing it on a canvas.
/// Returns null when the requester cancels. Admin official signatures keep
/// their separate upload flow in permit_signature_settings_dialog.dart.
Future<ReservationUpload?> showReservationSignatureDialog(
  BuildContext context, {
  required String requestId,
}) => showDialog<ReservationUpload>(
  context: context,
  barrierDismissible: false,
  barrierColor: context.srColors.scrim,
  builder: (_) => _ReservationSignatureDialog(requestId: requestId),
);

class _ReservationSignatureDialog extends StatefulWidget {
  const _ReservationSignatureDialog({required this.requestId});
  final String requestId;

  @override
  State<_ReservationSignatureDialog> createState() =>
      _ReservationSignatureDialogState();
}

class _ReservationSignatureDialogState
    extends State<_ReservationSignatureDialog> {
  final _controller = SignaturePadController();
  bool _rendering = false;
  String? _error;
  bool _lastHasInk = false;
  bool _lastIsEmpty = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onStrokesChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onStrokesChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onStrokesChanged() {
    final hasInk = _controller.hasEnoughInk;
    final isEmpty = _controller.isEmpty;
    if (hasInk != _lastHasInk || isEmpty != _lastIsEmpty || _error != null) {
      setState(() {
        _lastHasInk = hasInk;
        _lastIsEmpty = isEmpty;
        _error = null;
      });
    }
  }

  Future<void> _confirm() async {
    if (!_controller.hasEnoughInk) {
      setState(() => _error = 'Draw your full signature before confirming.');
      return;
    }
    setState(() {
      _rendering = true;
      _error = null;
    });
    try {
      final bytes = await renderSignaturePng(_controller.strokes);
      if (!mounted) return;
      Navigator.pop(
        context,
        ReservationUpload(
          name: 'signature-${widget.requestId}.png',
          mimeType: 'image/png',
          bytes: bytes,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _rendering = false;
        _error = 'Your signature could not be prepared. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final canEditStroke = !_lastIsEmpty && !_rendering;
    return SrAdaptiveDialog(
      maxWidth: 560,
      maxHeight: 540,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Sign your reservation permit',
                    style: SrType.subhead(),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: _rendering ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.border),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(SR.space20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Draw your signature in the box below using your finger, '
                    'stylus, or mouse.',
                    style: SrType.bodySm(),
                  ),
                  const SizedBox(height: SR.space12),
                  // Always white with dark ink, even in dark theme: this is a
                  // preview of the image printed on the official permit.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: kSignatureSurface,
                      border: Border.all(color: colors.border),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SignaturePad(
                        controller: _controller,
                        enabled: !_rendering,
                      ),
                    ),
                  ),
                  const SizedBox(height: SR.space8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Sign above the line.',
                          style: SrType.caption(color: colors.muted),
                        ),
                      ),
                      SrButton(
                        label: 'Undo',
                        kind: SrButtonKind.ghost,
                        dense: true,
                        onPressed: canEditStroke ? _controller.undo : null,
                      ),
                      const SizedBox(width: SR.space8),
                      SrButton(
                        label: 'Clear',
                        kind: SrButtonKind.ghost,
                        dense: true,
                        onPressed: canEditStroke ? _controller.clear : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: SR.space16),
                  Text(
                    'Material reservation changes will require a new signature.',
                    style: SrType.caption(color: colors.muted),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: SR.space8),
                    Text(_error!, style: SrType.bodySm(color: colors.redInk)),
                  ],
                ],
              ),
            ),
          ),
          Divider(height: 1, color: colors.border),
          Padding(
            padding: EdgeInsets.all(compact ? SR.space16 : SR.space20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SrButton(
                  label: 'Cancel',
                  kind: SrButtonKind.secondary,
                  onPressed: _rendering ? null : () => Navigator.pop(context),
                ),
                const SizedBox(width: SR.space8),
                SrButton(
                  label: _rendering ? 'Preparing…' : 'Confirm signature',
                  kind: SrButtonKind.primary,
                  onPressed: (_rendering || !_lastHasInk) ? null : _confirm,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
