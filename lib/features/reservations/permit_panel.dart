import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
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
            if (widget.state.isInternalAdmin && permit.ceoSignatureId != null)
              SrButton(
                label: 'Official copy',
                dense: true,
                onPressed: _busy ? null : () => _official(permit, request),
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
    if (widget.state.isInternalAdmin &&
        request.permitEligible &&
        !request.signatureSubmitted) {
      return [
        Text(
          'Request the requester’s e-signature before issuing this permit.',
          style: SrType.bodySm(),
        ),
        const SizedBox(height: SR.space8),
        SrButton(
          label: request.signatureRequested
              ? 'Signature requested'
              : 'Request e-signature',
          dense: true,
          onPressed: request.signatureRequested || _busy
              ? null
              : () => _requestSignature(request.id),
        ),
        const SizedBox(height: SR.space8),
        SrButton(
          label: 'Manage CEO signature',
          dense: true,
          onPressed: _busy ? null : _pickCeoSignature,
        ),
      ];
    }
    if (request.signatureRequested &&
        request.requesterId == widget.state.userAccount.id) {
      return [
        Text(
          'An Internal Admin has requested your e-signature. Upload a PNG or JPEG image to continue.',
          style: SrType.bodySm(),
        ),
        const SizedBox(height: SR.space8),
        SrButton(
          label: 'Upload e-signature',
          kind: SrButtonKind.primary,
          dense: true,
          onPressed: _busy ? null : () => _pickUserSignature(request),
        ),
      ];
    }
    if (request.signatureSubmitted) {
      return [
        Text(
          'E-signature submitted. The signed permit is being issued.',
          style: SrType.bodySm(),
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

  Future<Uint8List?> _render(
    ReservationPermit permit,
    ReservationRequest request, {
    bool official = false,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = permit.userSignatureId == null
          ? null
          : await widget.state.permitUserSignature(permit.userSignatureId!);
      final ceo = official
          ? await widget.state.officialCeoSignature(request.id, permit.id)
          : await widget.state.protectedCeoSignature(request.id, permit.id);
      if (permit.userSignatureId != null && (user == null || ceo == null)) {
        throw StateError('The protected permit signatures are unavailable.');
      }
      final bytes = await buildPermitPdf(
        permit,
        userSignature: user,
        ceoSignature: ceo,
        protectedCopy: !official,
      );
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
    final bytes = await _render(permit, request);
    if (bytes == null) return;
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  Future<void> _download(
    ReservationPermit permit,
    ReservationRequest request,
  ) async {
    if (await _openStoredPermit(permit)) return;
    final bytes = await _render(permit, request);
    if (bytes == null) return;
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

  Future<void> _official(
    ReservationPermit permit,
    ReservationRequest request,
  ) async {
    final bytes = await _render(permit, request, official: true);
    if (bytes != null) await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  Future<void> _requestSignature(String requestId) async {
    setState(() => _busy = true);
    await widget.state.requestReservationSignature(requestId);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickUserSignature(ReservationRequest request) async {
    final upload = await _chooseSignature('Select your e-signature');
    if (upload == null || request.signatureRequestId == null) return;
    setState(() => _busy = true);
    await widget.state.submitReservationSignature(
      signatureRequestId: request.signatureRequestId!,
      requestId: request.id,
      signature: upload,
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickCeoSignature() async {
    final upload = await _chooseSignature('Select CEO signature');
    if (upload == null) return;
    setState(() => _busy = true);
    await widget.state.uploadCeoSignature(upload);
    if (mounted) setState(() => _busy = false);
  }

  Future<ReservationUpload?> _chooseSignature(String title) async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
    );
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty || bytes.lengthInBytes > 5 * 1024 * 1024) {
      if (mounted) {
        setState(
          () =>
              _error = 'Signatures must be a PNG or JPEG no larger than 5 MB.',
        );
      }
      return null;
    }
    final mime = picked.name.toLowerCase().endsWith('.png')
        ? 'image/png'
        : 'image/jpeg';
    if (!mounted) return null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.memory(bytes, height: 130),
            const SizedBox(height: 12),
            const Text(
              'This image will be locked to the permit after confirmation.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return confirmed == true
        ? ReservationUpload(name: picked.name, mimeType: mime, bytes: bytes)
        : null;
  }
}
