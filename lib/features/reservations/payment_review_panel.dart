import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../model/payment.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';

import '../../theme/sr_theme.dart';

/// Payment evidence is rendered only after reservation RLS has already
/// enforced facility assignment and the snapshotted admin lane.
class PaymentReviewPanel extends StatelessWidget {
  const PaymentReviewPanel({
    super.key,
    required this.state,
    required this.request,
  });

  final AppState state;
  final ReservationRequest request;

  @override
  Widget build(BuildContext context) {
    final submitted = request.paymentTransactions
        .where((payment) => payment.status == PaymentDecisionStatus.submitted)
        .toList();
    if (request.totalAmountCentavos == 0 &&
        request.paymentTransactions.isEmpty) {
      return const SizedBox.shrink();
    }

    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Payment review', style: SrType.subhead()),
          const SizedBox(height: SR.space4),
          Text(
            '${request.aggregatePaymentStatus.label} · '
            '${pesoFromCentavos(request.verifiedAmountCentavos)} verified · '
            '${pesoFromCentavos(request.outstandingAmountCentavos)} remaining',
            style: SrType.caption(),
          ),
          if (request.paymentTransactions.isEmpty) ...[
            const SizedBox(height: SR.space12),
            Text('No payment proof submitted yet.', style: SrType.bodySm()),
          ] else ...[
            const SizedBox(height: SR.space12),
            for (final payment in request.paymentTransactions)
              _PaymentRow(
                state: state,
                payment: payment,
                canDecide: submitted.contains(payment),
              ),
          ],
        ],
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({
    required this.state,
    required this.payment,
    required this.canDecide,
  });

  final AppState state;
  final PaymentTransaction payment;
  final bool canDecide;

  @override
  Widget build(BuildContext context) {
    final pending = state.reservationActionsPending.contains(
      'payment:${payment.id}',
    );
    return Container(
      margin: const EdgeInsets.only(bottom: SR.space8),
      padding: const EdgeInsets.all(SR.space12),
      decoration: BoxDecoration(
        color: context.srColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(SR.rSm),
        border: Border.all(color: context.srColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: SR.space8,
            runSpacing: SR.space4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                pesoFromCentavos(payment.amountCentavos),
                style: SrType.body(w: 600),
              ),
              SrStatusChip(
                label: payment.status.label,
                tone: switch (payment.status) {
                  PaymentDecisionStatus.verified => SrTone.success,
                  PaymentDecisionStatus.needsCorrection => SrTone.warning,
                  PaymentDecisionStatus.rejected => SrTone.error,
                  _ => SrTone.warning,
                },
                dense: true,
              ),
              Text(
                '${payment.purpose.label} · Ref ${payment.referenceNumber}',
                style: SrType.caption(),
              ),
            ],
          ),
          if (payment.rejectionReason case final reason?) ...[
            const SizedBox(height: SR.space4),
            Text(reason, style: SrType.bodySm(color: context.srColors.redInk)),
          ],
          const SizedBox(height: SR.space8),
          Wrap(
            spacing: SR.space6,
            runSpacing: SR.space6,
            children: [
              SrButton(
                label: 'Open proof',
                dense: true,
                onPressed: () => _openProof(),
              ),
              if (canDecide) ...[
                SrButton(
                  label: pending ? 'Saving…' : 'Verify',
                  kind: SrButtonKind.success,
                  dense: true,
                  onPressed: pending
                      ? null
                      : () => state.decideReservationPayment(
                          payment: payment,
                          decision: 'verify',
                        ),
                ),
                SrButton(
                  label: 'Request correction',
                  kind: SrButtonKind.danger,
                  dense: true,
                  onPressed: pending ? null : () => _reject(context),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openProof() async {
    final url = await state.reservationPaymentProofUrl(payment);
    if (url != null) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _reject(BuildContext context) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request payment correction'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Correction needed',
            hintText: 'Explain what the requester must correct.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('Request correction'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason != null) {
      await state.decideReservationPayment(
        payment: payment,
        decision: 'reject',
        reason: reason,
      );
    }
  }
}
