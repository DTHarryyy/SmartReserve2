import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/notice.dart';
import '../../model/permit.dart';
import '../../model/payment.dart';
import '../../model/reservation.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../util/file_export.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import 'permit_signature_settings_dialog.dart';

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
  PermitReadiness? _readiness;

  bool get _admin =>
      widget.state.isInternalAdmin || widget.state.isExternalAdmin;

  @override
  void initState() {
    super.initState();
    unawaited(_loadReadiness());
  }

  @override
  void didUpdateWidget(covariant PermitPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.id != widget.request.id ||
        oldWidget.request.version != widget.request.version ||
        oldWidget.request.permit?.generationStatus !=
            widget.request.permit?.generationStatus) {
      unawaited(_loadReadiness());
    }
  }

  Future<void> _loadReadiness() async {
    final value = await widget.state.permitReadiness(widget.request.id);
    if (!mounted) return;
    setState(() => _readiness = value);
    if (value?.ready == true &&
        widget.request.permit?.isDownloadable != true &&
        !_busy) {
      unawaited(_generate());
    }
  }

  @override
  Widget build(BuildContext context) {
    final permit = widget.request.permit;
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
                  label: permit.generationStatus == PermitGenerationStatus.ready
                      ? permit.status.label
                      : _generationLabel(permit.generationStatus),
                  tone:
                      permit.generationStatus ==
                              PermitGenerationStatus.failed ||
                          permit.generationStatus ==
                              PermitGenerationStatus.blockedData
                      ? SrTone.error
                      : permit.status.tone,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: SR.space8),
          ..._body(context),
          if (_error != null) ...[
            const SizedBox(height: SR.space8),
            Text(_error!, style: SrType.bodySm(color: context.srColors.red)),
          ],
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final request = widget.request;
    final permit = request.permit;
    if (permit?.status == PermitStatus.void_ ||
        permit?.status == PermitStatus.superseded) {
      return [
        Text(
          permit!.status == PermitStatus.void_
              ? 'This permit is void${permit.voidReason == null ? '' : ' — ${permit.voidReason}'}.'
              : 'This permit was superseded and is no longer downloadable.',
          style: SrType.bodySm(color: context.srColors.redInk),
        ),
      ];
    }
    if (permit?.isDownloadable == true) {
      return [
        Text(permit!.permitNumber, style: SrType.body(w: 600)),
        Text(
          '${permit.templateKind.label} · Issued ${formatStamp(campusWallTime(permit.issuedAt))}',
          style: SrType.caption(),
        ),
        const SizedBox(height: SR.space12),
        Text(
          'Print this official permit and bring it on the reservation date.',
          style: SrType.bodySm(),
        ),
        const SizedBox(height: SR.space12),
        Wrap(
          spacing: SR.space8,
          runSpacing: SR.space8,
          children: [
            SrButton(
              label: _busy ? 'Opening…' : 'View Permit',
              kind: SrButtonKind.primary,
              dense: true,
              onPressed: _busy ? null : () => _view(permit),
            ),
            SrButton(
              label: 'Download PDF',
              dense: true,
              onPressed: _busy ? null : () => _download(permit),
            ),
          ],
        ),
      ];
    }
    if (request.lifecycleStatus == ReservationLifecycleStatus.pendingApproval ||
        request.lifecycleStatus ==
            ReservationLifecycleStatus.changesRequested) {
      return [
        Text(
          'Permit not yet available. Your reservation must be approved first.',
          style: SrType.bodySm(),
        ),
      ];
    }
    final widgets = <Widget>[];
    if (request.signatureRequested &&
        request.requesterId == widget.state.userAccount.id) {
      widgets.addAll([
        Text(
          'Your approved reservation needs your reservation-specific signature.',
          style: SrType.bodySm(),
        ),
        const SizedBox(height: SR.space8),
        SrButton(
          label: 'Upload e-signature',
          kind: SrButtonKind.primary,
          dense: true,
          onPressed: _busy ? null : () => _pickUserSignature(request),
        ),
      ]);
    } else if (request.adminLane == 'external' &&
        request.outstandingAmountCentavos > 0) {
      widgets.add(
        Text(
          'Payment verification is incomplete. Verified: '
          '${pesoFromCentavos(request.verifiedAmountCentavos)} · Remaining: '
          '${pesoFromCentavos(request.outstandingAmountCentavos)}. You may submit a requested signature while payment continues.',
          style: SrType.bodySm(),
        ),
      );
    } else if (permit?.generationStatus == PermitGenerationStatus.failed) {
      widgets.add(
        Text(
          _admin
              ? 'Generation failed (${permit?.generationErrorCode ?? 'generation_failed'}). Retry after checking readiness.'
              : 'The permit could not be prepared. The assigned administrator has been notified.',
          style: SrType.bodySm(),
        ),
      );
    } else if (permit?.generationStatus == PermitGenerationStatus.blockedData) {
      widgets.add(
        Text(
          _admin
              ? 'Generation is blocked by printable content: ${permit?.generationErrorCode ?? 'content_does_not_fit'}.'
              : 'Permit details need administrator attention before the document can be prepared.',
          style: SrType.bodySm(),
        ),
      );
    } else {
      widgets.add(
        Text(
          request.signatureSubmitted
              ? 'Your requirements are complete. The permit is being prepared.'
              : 'Waiting for the remaining permit requirements.',
          style: SrType.bodySm(),
        ),
      );
    }
    if (request.adminLane == 'external' &&
        request.requesterId == widget.state.userAccount.id &&
        _readiness?.blockerCodes.contains('external_details_required') ==
            true) {
      widgets.addAll([
        const SizedBox(height: SR.space8),
        SrButton(
          label: 'Complete permit details',
          kind: SrButtonKind.primary,
          dense: true,
          onPressed: _busy ? null : () => _completeExternalDetails(request),
        ),
      ]);
    }
    if (_admin) {
      if (_readiness != null && _readiness!.blockerCodes.isNotEmpty) {
        widgets.addAll([
          const SizedBox(height: SR.space12),
          Text('Readiness checklist', style: SrType.body(w: 600)),
          const SizedBox(height: SR.space4),
          for (final code in _readiness!.blockerCodes)
            Text(
              '• ${_readiness!.messageFor(code)}',
              style: SrType.bodySm(color: context.srColors.muted),
            ),
        ]);
      }
      widgets.addAll([
        const SizedBox(height: SR.space12),
        Wrap(
          spacing: SR.space8,
          runSpacing: SR.space8,
          children: [
            if (!request.signatureRequested && !request.signatureSubmitted)
              SrButton(
                label: 'Request signature',
                dense: true,
                onPressed: _busy ? null : _requestSignature,
              ),
            SrButton(
              label: permit == null ? 'Generate' : 'Retry generation',
              dense: true,
              onPressed: _busy || _readiness?.ready != true ? null : _generate,
            ),
            SrButton(
              label: 'Signature settings',
              dense: true,
              onPressed: _busy
                  ? null
                  : () => showPermitSignatureSettingsDialog(
                      context,
                      state: widget.state,
                    ),
            ),
          ],
        ),
        SrButton(
          label: 'Preview populated permit',
          dense: true,
          onPressed: _busy || _readiness?.ready != true ? null : _preview,
        ),
      ]);
    }
    return widgets;
  }

  String _generationLabel(PermitGenerationStatus status) => switch (status) {
    PermitGenerationStatus.pending => 'Pending',
    PermitGenerationStatus.generating => 'Generating',
    PermitGenerationStatus.ready => 'Ready',
    PermitGenerationStatus.blockedData => 'Blocked',
    PermitGenerationStatus.failed => 'Failed',
  };

  Future<void> _generate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.state.issuePermit(widget.request.id);
    if (mounted) {
      setState(() {
        _busy = false;
        if (!ok) _error = 'The permit could not be prepared.';
      });
    }
  }

  Future<void> _preview() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final bytes = await widget.state.previewPermit(widget.request.id);
    if (mounted) setState(() => _busy = false);
    if (bytes == null) {
      if (mounted) {
        setState(() => _error = 'The populated preview is unavailable.');
      }
      return;
    }
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: 'Permit preview',
    );
  }

  Future<void> _view(ReservationPermit permit) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final bytes = await widget.state.permitPdfBytes(permit);
    if (mounted) setState(() => _busy = false);
    if (bytes == null) {
      if (mounted) {
        setState(() => _error = 'The stored final permit is unavailable.');
      }
      return;
    }
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  Future<void> _download(ReservationPermit permit) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final bytes = await widget.state.permitPdfBytes(permit);
    if (bytes == null) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'The stored final permit is unavailable.';
        });
      }
      return;
    }
    final result = await saveBinaryFile(
      baseName: permit.permitNumber,
      extension: 'pdf',
      bytes: bytes,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    widget.state.showToast(
      ToastMessage(
        result.ok
            ? 'Permit downloaded. Print it before you arrive.'
            : 'The permit could not be saved: ${result.error}',
        tone: result.ok ? AdvisoryTone.info : AdvisoryTone.block,
      ),
    );
  }

  Future<void> _requestSignature() async {
    setState(() => _busy = true);
    await widget.state.requestReservationSignature(widget.request.id);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickUserSignature(ReservationRequest request) async {
    final upload = await _chooseSignature();
    if (upload == null || request.signatureRequestId == null) return;
    setState(() => _busy = true);
    await widget.state.submitReservationSignature(
      signatureRequestId: request.signatureRequestId!,
      requestId: request.id,
      signature: upload,
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<ReservationUpload?> _chooseSignature() async {
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
        title: const Text('Confirm reservation signature'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.memory(bytes, height: 130),
            const SizedBox(height: 12),
            const Text(
              'Material reservation changes will require a new signature.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
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

  Future<void> _completeExternalDetails(ReservationRequest request) async {
    if (request.signatureSubmitted) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Change signed permit details?'),
          content: const Text(
            'The current signature will be superseded and a fresh signature will be requested.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }
    final company = TextEditingController(
      text: request.externalCompanyOrganization,
    );
    final address = TextEditingController(
      text: request.externalCompleteAddress,
    );
    final contacts = TextEditingController(
      text: request.externalContactNumbers.join(', '),
    );
    final fee = TextEditingController(
      text: request.externalAdmissionFeeCentavos == null
          ? ''
          : (request.externalAdmissionFeeCentavos! / 100).toStringAsFixed(2),
    );
    var individual = request.externalCompanyOrganization == 'Individual';
    var noFee = request.externalAdmissionFeeCentavos == 0;
    final details = await showDialog<ExternalPermitDetails>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('External permit details'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Individual'),
                    value: individual,
                    onChanged: (value) =>
                        setDialogState(() => individual = value ?? false),
                  ),
                  if (!individual)
                    TextField(
                      controller: company,
                      decoration: const InputDecoration(
                        labelText: 'Company / organization',
                      ),
                    ),
                  TextField(
                    controller: address,
                    maxLength: 110,
                    decoration: const InputDecoration(
                      labelText: 'Complete address',
                    ),
                  ),
                  TextField(
                    controller: contacts,
                    decoration: const InputDecoration(
                      labelText: 'Contact number(s)',
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('No admission fee'),
                    value: noFee,
                    onChanged: (value) =>
                        setDialogState(() => noFee = value ?? true),
                  ),
                  if (!noFee)
                    TextField(
                      controller: fee,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Admission fee (PHP)',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final contactValues = contacts.text
                    .split(RegExp(r'[,;/\n]'))
                    .map((value) => value.trim())
                    .where((value) => value.isNotEmpty)
                    .toList();
                final amount = noFee ? 0 : double.tryParse(fee.text.trim());
                if ((!individual && company.text.trim().isEmpty) ||
                    address.text.trim().isEmpty ||
                    contactValues.isEmpty ||
                    amount == null ||
                    amount < 0) {
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  ExternalPermitDetails(
                    companyOrOrganization: individual
                        ? 'Individual'
                        : company.text.trim(),
                    completeAddress: address.text.trim(),
                    contactNumbers: contactValues,
                    admissionFeeCentavos: noFee ? 0 : (amount * 100).round(),
                  ),
                );
              },
              child: const Text('Save and request fresh signature'),
            ),
          ],
        ),
      ),
    );
    company.dispose();
    address.dispose();
    contacts.dispose();
    fee.dispose();
    if (details == null) return;
    setState(() => _busy = true);
    await widget.state.updateExternalPermitDetails(request.id, details);
    if (mounted) {
      setState(() => _busy = false);
      unawaited(_loadReadiness());
    }
  }
}
