import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../model/notice.dart';
import 'sr_components.dart';
import 'sr_controls.dart';

/// Settings row that registers this device for push notifications. Shared by
/// the renter and admin profiles so both roles can opt in; the permission
/// prompt only ever appears behind this explicit tap.
class PushEnableRow extends StatefulWidget {
  const PushEnableRow({super.key, required this.state});

  final AppState state;

  @override
  State<PushEnableRow> createState() => _PushEnableRowState();
}

class _PushEnableRowState extends State<PushEnableRow> {
  bool _busy = false;

  Future<void> _enable() async {
    setState(() => _busy = true);
    final granted = await widget.state.enablePushNotifications();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!granted) {
      widget.state.showToast(
        const ToastMessage(
          'Push notifications were not enabled. Check your browser or device permission settings.',
          tone: AdvisoryTone.block,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final push = widget.state.pushService;
    if (push == null || !push.isSupported) {
      return const SrListRow(
        label: 'Enable push on this device',
        value: 'Not supported here',
      );
    }
    if (push.isRegistered) {
      return const SrListRow(
        label: 'Push notifications',
        value: 'Active on this device',
      );
    }
    return SrListRow(
      key: const Key('push-enable-row'),
      label: 'Enable push on this device',
      trailing: SrButton(
        label: _busy ? 'Requesting…' : 'Enable',
        dense: true,
        fontSize: 11,
        onPressed: _busy ? null : _enable,
      ),
    );
  }
}
