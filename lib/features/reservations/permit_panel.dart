import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../model/notice.dart';
import '../../model/permit.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../util/file_export.dart';
import '../../util/permit_pdf.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';

import '../../theme/sr_theme.dart';

/// The permit card shown on both the admin decision panel and the
/// requester's own reservation detail. What it offers depends entirely on
/// server-derived state (`request.permit`, `request.permitEligible`) --
/// nothing here decides eligibility, it only reflects it.
class PermitPanel extends StatefulWidget {
  const PermitPanel({super.key, required this.state, required this.request});

  final AppState state;
  final ReservationRequest request;

  @override
  State<PermitPanel> createState() => _PermitPanelState();
}

class _PermitPanelState extends State<PermitPanel> {
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final permit = request.permit;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Permit', style: SrType.subhead()),
              const Spacer(),
              if (permit != null)
                SrStatusChip(
                  label: permit.status.label,
                  tone: permit.status.tone,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: SR.space8),
          ..._body(context, request, permit),
          if (_error != null) ...[
            const SizedBox(height: SR.space8),
            Text(_error!, style: SrType.bodySm(color: context.srColors.red)),
          ],
        ],
      ),
    );
  }

  List<Widget> _body(
    BuildContext context,
    ReservationRequest request,
    ReservationPermit? permit,
  ) {
    if (permit != null && permit.status == PermitStatus.active) {
      return [
        Text(permit.permitNumber, style: SrType.body(w: 600)),
        Text(
          'Issued ${formatStamp(campusWallTime(permit.issuedAt))}',
          style: SrType.caption(),
        ),
        const SizedBox(height: SR.space12),
        Text(
          'Your reservation has been confirmed and your approved facility '
          'reservation permit is now available. Please download and print '
          'the document and bring the printed copy when you arrive at the '
          'facility.',
          style: SrType.bodySm(),
        ),
        const SizedBox(height: SR.space12),
        Wrap(
          spacing: SR.space8,
          runSpacing: SR.space8,
          children: [
            SrButton(
              label: _busy ? 'Preparing…' : 'View Permit',
              kind: SrButtonKind.primary,
              dense: true,
              onPressed: _busy ? null : () => _view(permit, request),
            ),
            SrButton(
              label: 'Download PDF',
              dense: true,
              onPressed: _busy ? null : () => _download(permit, request),
            ),
          ],
        ),
      ];
    }
    if (permit != null) {
      return [
        Text(
          permit.status == PermitStatus.void_
              ? 'This permit is void${permit.voidReason == null ? '' : ' — ${permit.voidReason}'}.'
              : 'This permit has been superseded by a newer version.',
          style: SrType.bodySm(color: context.srColors.redInk),
        ),
      ];
    }
    if (request.permitEligible) {
      return [
        Text('Your permit is being prepared.', style: SrType.bodySm()),
        const SizedBox(height: SR.space8),
        SrButton(
          label: 'Check for permit',
          dense: true,
          onPressed: () => widget.state.issuePermit(request.id),
        ),
      ];
    }
    return [
      Text(
        request.totalAmountCentavos > 0
            ? 'Locked until fully paid.'
            : 'Available once the reservation is approved and confirmed.',
        style: SrType.bodySm(color: context.srColors.muted),
      ),
    ];
  }

  Future<Uint8List?> _render(ReservationPermit permit) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await buildPermitPdf(permit);
      return bytes;
    } catch (error) {
      setState(() => _error = 'The permit could not be prepared: $error');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _view(
    ReservationPermit permit,
    ReservationRequest request,
  ) async {
    if (await _openStoredPermit(permit)) return;
    final bytes = await _render(permit);
    if (bytes == null) return;
    _persist(permit, request, bytes);
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  Future<void> _download(
    ReservationPermit permit,
    ReservationRequest request,
  ) async {
    if (await _openStoredPermit(permit)) return;
    final bytes = await _render(permit);
    if (bytes == null) return;
    _persist(permit, request, bytes);
    final result = await saveBinaryFile(
      baseName: permit.permitNumber,
      extension: 'pdf',
      bytes: bytes,
    );
    if (!mounted) return;
    if (result.ok) {
      widget.state.showToast(
        const ToastMessage('Permit downloaded. Print it before you arrive.'),
      );
    } else {
      widget.state.showToast(
        ToastMessage(
          'The permit could not be saved: ${result.error}',
          tone: AdvisoryTone.block,
        ),
      );
    }
  }

  Future<bool> _openStoredPermit(ReservationPermit permit) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final url = await widget.state.permitPdfUrl(permit);
      if (url == null) return false;
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _persist(
    ReservationPermit permit,
    ReservationRequest request,
    Uint8List bytes,
  ) {
    final requesterId = request.requesterId;
    if (requesterId == null) return;
    unawaited(
      widget.state.uploadPermitPdf(
        permitId: permit.id,
        requestId: request.id,
        requesterId: requesterId,
        permitNumber: permit.permitNumber,
        version: permit.version,
        bytes: bytes,
      ),
    );
  }
}
