import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/facility.dart';
import '../../model/notice.dart';
import '../../model/payment.dart';
import '../../model/reservation.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';

enum PaymentProofMode { initialSubmission, correctionSubmission }

Future<bool> showPaymentProofSheet(
  BuildContext context, {
  required AppState state,
  required ReservationRequest request,
  PaymentProofMode mode = PaymentProofMode.initialSubmission,
  PaymentTransaction? correctingPayment,
}) async {
  Facility? facility;
  for (final item in state.facilities) {
    if (item.id == request.facilityId) {
      facility = item;
      break;
    }
  }
  FacilityPaymentMethod? method = request.paymentMethod;
  if (method == null) {
    for (final item
        in facility?.paymentMethods ?? const <FacilityPaymentMethod>[]) {
      if (item.enabled) {
        method = item;
        break;
      }
    }
  }
  if (method == null) {
    state.showToast(
      const ToastMessage(
        'This facility has not published a GCash account yet. Contact the administrator before sending payment.',
        tone: AdvisoryTone.block,
      ),
    );
    return false;
  }
  final selectedMethod = method;

  final fullPaymentDue =
      request.balanceDueAt != null &&
      !request.balanceDueAt!.isAfter(campusNow());
  final depositRemaining =
      request.requiredDownPaymentCentavos - request.verifiedAmountCentavos;
  final initialAmount =
      mode == PaymentProofMode.correctionSubmission && correctingPayment != null
      ? correctingPayment.amountCentavos
      : request.lifecycleStatus == ReservationLifecycleStatus.awaitingPayment &&
            !fullPaymentDue
      ? (depositRemaining < 1
            ? 1
            : depositRemaining > request.outstandingAmountCentavos
            ? request.outstandingAmountCentavos
            : depositRemaining)
      : request.outstandingAmountCentavos;

  return await showDialog<bool>(
        context: context,
        builder: (context) => _PaymentProofDialog(
          state: state,
          request: request,
          method: selectedMethod,
          mode: mode,
          correctingPayment: correctingPayment,
          initialAmountCentavos: initialAmount,
        ),
      ) ??
      false;
}

class _PaymentProofDialog extends StatefulWidget {
  const _PaymentProofDialog({
    required this.state,
    required this.request,
    required this.method,
    required this.mode,
    required this.initialAmountCentavos,
    this.correctingPayment,
  });

  final AppState state;
  final ReservationRequest request;
  final FacilityPaymentMethod method;
  final PaymentProofMode mode;
  final int initialAmountCentavos;
  final PaymentTransaction? correctingPayment;

  @override
  State<_PaymentProofDialog> createState() => _PaymentProofDialogState();
}

class _PaymentProofDialogState extends State<_PaymentProofDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: (widget.initialAmountCentavos / 100).toStringAsFixed(2),
  );
  late final TextEditingController _reference = TextEditingController(
    text: widget.correctingPayment?.referenceNumber ?? '',
  );
  ReservationUpload? _proof;
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final correction = widget.mode == PaymentProofMode.correctionSubmission;
    final payment = widget.correctingPayment;
    return AlertDialog(
      title: Text(correction ? 'Fix payment proof' : 'Submit GCash proof'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${widget.method.accountName} · ${widget.method.accountNumber}',
                style: SrType.body(w: 600),
              ),
              if (widget.method.instructions.isNotEmpty)
                Text(
                  widget.method.instructions,
                  style: SrType.bodySm(color: context.srColors.muted),
                ),
              if (correction && payment != null) ...[
                const SizedBox(height: SR.space12),
                Container(
                  padding: const EdgeInsets.all(SR.space8),
                  decoration: BoxDecoration(
                    color: context.srColors.amberTint,
                    borderRadius: BorderRadius.circular(SR.rSm),
                  ),
                  child: Text(
                    'Reason: ${payment.rejectionReason ?? 'Please replace the proof.'}\n'
                    'Correct by: ${payment.correctionDueAt == null ? 'deadline unavailable' : formatStamp(campusWallTime(payment.correctionDueAt!))}',
                    style: SrType.bodySm(color: context.srColors.amberTitle),
                  ),
                ),
              ],
              const SizedBox(height: SR.space12),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Amount (PHP)'),
              ),
              const SizedBox(height: SR.space8),
              TextField(
                controller: _reference,
                decoration: const InputDecoration(
                  labelText: 'GCash reference number',
                ),
              ),
              const SizedBox(height: SR.space12),
              OutlinedButton.icon(
                onPressed: _submitting ? null : _pickProof,
                icon: const Icon(Icons.attach_file_rounded),
                label: Text(_proof?.name ?? 'Choose receipt or screenshot'),
              ),
              if (_error != null) ...[
                const SizedBox(height: SR.space8),
                Text(
                  _error!,
                  style: SrType.bodySm(color: context.srColors.red),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(_submitting ? 'Submitting...' : 'Submit proof'),
        ),
      ],
    );
  }

  Future<void> _pickProof() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty || bytes.lengthInBytes > 10 * 1024 * 1024) {
      setState(() => _error = 'Proof must be at most 10 MB.');
      return;
    }
    final extension = picked.name.split('.').last.toLowerCase();
    final mime = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'pdf' => 'application/pdf',
      _ => '',
    };
    if (mime.isEmpty) {
      setState(() => _error = 'Use a JPG, PNG, or PDF receipt.');
      return;
    }
    setState(() {
      _proof = ReservationUpload(
        name: picked.name,
        mimeType: mime,
        bytes: bytes,
      );
      _error = null;
    });
  }

  Future<void> _submit() async {
    final pesos = double.tryParse(_amount.text.trim());
    if (pesos == null ||
        pesos <= 0 ||
        _proof == null ||
        _reference.text.trim().length < 6) {
      setState(() => _error = 'Enter a valid amount, reference, and proof.');
      return;
    }
    setState(() => _submitting = true);
    final centavos = (pesos * 100).round();
    final ok =
        widget.mode == PaymentProofMode.correctionSubmission &&
            widget.correctingPayment != null
        ? await widget.state.correctReservationPayment(
            payment: widget.correctingPayment!,
            amountCentavos: centavos,
            referenceNumber: _reference.text,
            proof: _proof!,
          )
        : await widget.state.submitReservationPayment(
            request: widget.request,
            purpose:
                widget.request.lifecycleStatus ==
                    ReservationLifecycleStatus.awaitingPayment
                ? PaymentPurpose.downPayment
                : PaymentPurpose.balance,
            amountCentavos: centavos,
            referenceNumber: _reference.text,
            proof: _proof!,
          );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) Navigator.pop(context, true);
  }
}
