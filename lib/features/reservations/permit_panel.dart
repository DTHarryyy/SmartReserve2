import 'dart:async';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../app/app_state.dart';
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
import 'reservation_permit_mapping_dialog.dart';
import 'reservation_signature_dialog.dart';

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

  bool _isSignedInRequester(ReservationRequest request) =>
      !_admin &&
      widget.state.hasSession &&
      widget.state.sessionProfile?.id == request.requesterId;

  PermitRequesterSignatureState _signatureState(ReservationRequest request) =>
      _readiness?.requesterSignatureState ??
      (request.signatureRequested
          ? PermitRequesterSignatureState.requested
          : request.signatureSubmitted
          ? PermitRequesterSignatureState.current
          : PermitRequesterSignatureState.missing);

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
    setState(() {
      _readiness = value;
      // A completed requester signature is authoritative. Clear any local
      // error left over from an earlier attempt; the requester has no permit
      // generation action to repeat.
      if (!_admin && widget.request.signatureSubmitted) _error = null;
    });
  }

  Future<void> _configurePermitMappings(ReservationRequest request) async {
    final readiness = _readiness;
    if (readiness == null || readiness.configurationReady) {
      return;
    }
    final saved = await showReservationPermitMappingDialog(
      context,
      state: widget.state,
      requestId: request.id,
      facilityName: request.facility,
      readiness: readiness,
    );
    if (!mounted || saved != true) return;
    await _loadReadiness();
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
          if (_admin && (permit != null || _readiness != null)) ...[
            Text(
              'Template: ${(permit?.templateKind ?? _readiness!.templateKind).label}',
              style: SrType.caption(),
            ),
            const SizedBox(height: SR.space8),
          ],
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
    final signatureState = _signatureState(request);
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
    if (_readiness?.configurationReady == false) {
      final missing = _readiness!.missingMappings;
      if (!_admin) {
        return [
          Text(
            'Permit setup is incomplete. An administrator must complete the facility form mappings before your e-signature can be requested.',
            style: SrType.bodySm(),
          ),
        ];
      }
      return [
        Text(
          'Permit blocked — ${missing.length} ${missing.length == 1 ? 'required mapping is' : 'required mappings are'} incomplete.',
          style: SrType.bodySm(color: context.srColors.redInk),
        ),
        const SizedBox(height: SR.space8),
        for (final item in missing)
          Text(
            '• ${item.label}',
            style: SrType.bodySm(color: context.srColors.muted),
          ),
        const SizedBox(height: SR.space12),
        SrButton(
          label: 'Complete required mappings',
          kind: SrButtonKind.primary,
          dense: true,
          onPressed: _busy ? null : () => _configurePermitMappings(request),
        ),
      ];
    }
    if (permit?.isGenerated == true) {
      final generatedPermit = permit!;
      final delivered = generatedPermit.isDelivered;
      if (!_admin && !delivered) {
        return [
          Text(
            'Your official permit has been prepared. It will be sent to you by the assigned administrator.',
            style: SrType.bodySm(),
          ),
        ];
      }
      return [
        Text(generatedPermit.permitNumber, style: SrType.body(w: 600)),
        Text(
          '${generatedPermit.templateKind.label} · Issued ${formatStamp(campusWallTime(generatedPermit.issuedAt))}',
          style: SrType.caption(),
        ),
        const SizedBox(height: SR.space12),
        Text(
          delivered
              ? 'Official permit sent. Download and print it before the reservation date.'
              : 'Official permit generated. Send it to the requester when you are ready.',
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
              onPressed: _busy ? null : () => _view(generatedPermit),
            ),
            SrButton(
              label: 'Download PDF',
              dense: true,
              onPressed: _busy ? null : () => _download(generatedPermit),
            ),
            if (_admin && !delivered)
              SrButton(
                label: _busy ? 'Sending…' : 'Send permit to requester',
                dense: true,
                onPressed: _busy ? null : () => _deliver(generatedPermit),
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
    if (signatureState == PermitRequesterSignatureState.requested &&
        request.signatureRequested &&
        _isSignedInRequester(request)) {
      widgets.addAll([
        Text(
          'Your approved reservation needs your signature. Draw it here to '
          'let the administrator prepare your official permit.',
          style: SrType.bodySm(),
        ),
        const SizedBox(height: SR.space8),
        SrButton(
          label: 'Sign e-signature',
          kind: SrButtonKind.primary,
          dense: true,
          onPressed: _busy ? null : () => _signReservation(request),
        ),
      ]);
    } else if (signatureState == PermitRequesterSignatureState.requested &&
        _admin) {
      widgets.add(
        Text(
          'An e-signature request is active. The requester must sign from My reservations before an official permit can be generated or sent.',
          style: SrType.bodySm(),
        ),
      );
    } else if (signatureState == PermitRequesterSignatureState.stale) {
      widgets.add(
        Text(
          _admin
              ? 'The recorded e-signature no longer matches the current reservation details. Request an updated signature before generating the permit.'
              : 'Your reservation details changed after you signed. The assigned administrator must send an updated signature request.',
          style: SrType.bodySm(),
        ),
      );
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
    } else if (!_admin &&
        signatureState == PermitRequesterSignatureState.current) {
      // A requester has completed the only step they control. A previous
      // generation attempt can fail while official signatures or mappings are
      // being configured; showing that as the requester's failure is both
      // misleading and leaves them with no useful action.
      widgets.add(
        Text(
          'Your e-signature is recorded. The assigned administrator is completing the remaining official permit steps.',
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
          signatureState == PermitRequesterSignatureState.current
              ? 'Your e-signature is recorded. The system is waiting for the remaining official permit requirements.'
              : 'Waiting for the remaining permit requirements.',
          style: SrType.bodySm(),
        ),
      );
    }
    if (request.adminLane == 'external' &&
        _isSignedInRequester(request) &&
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
              '• ${code == 'requester_signature_required' && signatureState == PermitRequesterSignatureState.stale ? 'The requester must sign the updated reservation details.' : _readiness!.messageFor(code)}',
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
            if (_readiness?.configurationReady == true &&
                (signatureState == PermitRequesterSignatureState.missing ||
                    signatureState == PermitRequesterSignatureState.stale))
              SrButton(
                label: signatureState == PermitRequesterSignatureState.stale
                    ? 'Request updated signature'
                    : 'Request signature',
                dense: true,
                onPressed: _busy ? null : _requestSignature,
              ),
            if (signatureState == PermitRequesterSignatureState.requested)
              SrButton(
                label: 'Resend e-signature request',
                dense: true,
                onPressed: _busy ? null : _requestSignature,
              ),
            if (_readiness?.ready == true && permit?.isGenerated != true)
              SrButton(
                label: permit == null ? 'Generate permit' : 'Retry generation',
                dense: true,
                onPressed: _busy ? null : _generate,
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
        if (_readiness?.ready == true)
          SrButton(
            label: 'Preview populated permit',
            dense: true,
            onPressed: _busy ? null : _preview,
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
    // Issuing an official permit is an explicit administrator action. It must
    // never run in the requester's session just because the panel refreshed.
    if (!_admin || _busy) return;
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
            ? (result.shared
                  ? 'Permit ready. Save or print it before you arrive.'
                  : 'Permit downloaded. Print it before you arrive.')
            : 'The permit could not be saved: ${result.error}',
        tone: result.ok ? AdvisoryTone.info : AdvisoryTone.block,
      ),
    );
  }

  Future<void> _deliver(ReservationPermit permit) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final delivered = await widget.state.deliverReservationPermit(permit.id);
    if (mounted) {
      setState(() {
        _busy = false;
        if (!delivered) {
          _error = 'The permit was generated but could not be sent. Try again.';
        }
      });
    }
  }

  Future<void> _requestSignature() async {
    setState(() => _busy = true);
    await widget.state.requestReservationSignature(widget.request.id);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _signReservation(ReservationRequest request) async {
    if (request.signatureRequestId == null) return;
    final upload = await showReservationSignatureDialog(
      context,
      requestId: request.id,
    );
    if (upload == null || !mounted) return;
    setState(() => _busy = true);
    await widget.state.submitReservationSignature(
      signatureRequestId: request.signatureRequestId!,
      requestId: request.id,
      signature: upload,
    );
    if (mounted) setState(() => _busy = false);
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
