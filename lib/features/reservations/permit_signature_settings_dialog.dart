import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/permit.dart';

Future<void> showPermitSignatureSettingsDialog(
  BuildContext context, {
  required AppState state,
}) => showDialog<void>(
  context: context,
  builder: (_) => _PermitSignatureSettingsDialog(state: state),
);

class _PermitSignatureSettingsDialog extends StatefulWidget {
  const _PermitSignatureSettingsDialog({required this.state});
  final AppState state;
  @override
  State<_PermitSignatureSettingsDialog> createState() =>
      _PermitSignatureSettingsDialogState();
}

class _PermitSignatureSettingsDialogState
    extends State<_PermitSignatureSettingsDialog> {
  bool _busy = false;
  String? _error;

  List<OfficialSignatureSlot> get _slots => widget.state.isInternalAdmin
      ? const [OfficialSignatureSlot.internalApprover]
      : const [
          OfficialSignatureSlot.externalRecommender,
          OfficialSignatureSlot.externalAuthorizedOfficial,
        ];

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Official permit signatures'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Each slot matches the fixed printed identity on its official template. Replacements affect future permits only.',
          ),
          const SizedBox(height: 16),
          for (final slot in _slots)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(slot.label),
              subtitle: Text(_identity(slot)),
              trailing: Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy ? null : () => _preview(slot),
                    child: const Text('Preview'),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : () => _upload(slot),
                    child: const Text('Replace'),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );

  String _identity(OfficialSignatureSlot slot) => switch (slot) {
    OfficialSignatureSlot.internalApprover =>
      'DR. POLICARPIO L. MABBORANG, JR., ASEAN ENGR. — Campus Executive Officer',
    OfficialSignatureSlot.externalRecommender =>
      'DIANA GRACE C. LICOPIT, MBA — Business Coordinator',
    OfficialSignatureSlot.externalAuthorizedOfficial =>
      'DR. POLICARPIO L. MABBORANG, JR., ASEAN ENGR. — President/Authorized Official',
  };

  Future<void> _preview(OfficialSignatureSlot slot) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final data = await widget.state.previewOfficialSignature(slot);
    if (!mounted) return;
    setState(() => _busy = false);
    final encoded = data?['imageBase64'];
    if (encoded is! String) {
      setState(
        () => _error = 'No active signature is configured for ${slot.label}.',
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(slot.label),
        content: Image.memory(base64Decode(encoded), height: 150),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _upload(OfficialSignatureSlot slot) async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty || bytes.lengthInBytes > 5 * 1024 * 1024) {
      setState(() => _error = 'Choose a PNG or JPEG no larger than 5 MB.');
      return;
    }
    final mime = picked.name.toLowerCase().endsWith('.png')
        ? 'image/png'
        : 'image/jpeg';
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Replace ${slot.label}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_identity(slot)),
            const SizedBox(height: 12),
            Image.memory(bytes, height: 130),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm replacement'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.state.uploadOfficialSignature(
      slot,
      ReservationUpload(name: picked.name, mimeType: mime, bytes: bytes),
    );
    if (mounted) {
      setState(() {
        _busy = false;
        if (!ok) _error = 'The signature was not updated.';
      });
    }
  }
}
