import 'dart:convert';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_state.dart';
import '../../model/account.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/sr_controls.dart';

Future<void> showInviteDialog(BuildContext context, AppState state) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x7010141A),
      builder: (_) => _InviteDialog(state: state),
    );

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.state});

  final AppState state;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _email = TextEditingController();
  final _note = TextEditingController();
  final _credentialEmail = TextEditingController();
  final _credentialPassword = TextEditingController();
  AccountRole _role = AccountRole.internalAdmin;
  AdministratorCredentials? _credentials;
  String? _error;
  String? _notice;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _note.dispose();
    _credentialEmail.dispose();
    _credentialPassword.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final result = await widget.state.createAdministrator(
      _email.text,
      _role,
      _note.text,
    );
    if (!mounted) return;
    if (result.error != null) {
      setState(() {
        _busy = false;
        _error = result.error;
      });
      return;
    }
    setState(() {
      _busy = false;
      _credentials = result.credentials;
      _credentialEmail.text = result.credentials!.email;
      _credentialPassword.text = result.credentials!.temporaryPassword;
    });
  }

  Future<void> _saveCredentials() => _export(() async {
    await FileSaver.instance.saveAs(
      name: 'smartreserve-admin-credentials',
      bytes: Uint8List.fromList(utf8.encode(_credentials!.exportText)),
      fileExtension: 'txt',
      mimeType: MimeType.text,
    );
    _notice = 'Credentials file saved. Keep it in a secure location.';
  });

  Future<void> _shareCredentials() => _export(() async {
    await SharePlus.instance.share(
      ShareParams(
        title: 'SmartReserve administrator credentials',
        subject: 'SmartReserve administrator credentials',
        text: _credentials!.exportText,
      ),
    );
    _notice = 'Credentials were sent to the share sheet.';
  });

  Future<void> _export(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
      if (mounted) setState(() => _busy = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Credentials could not be exported. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    elevation: 0,
    insetPadding: const EdgeInsets.all(20),
    child: Container(
      constraints: const BoxConstraints(maxWidth: 460, maxHeight: 720),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: SR.dialogShadow,
      ),
      child: SingleChildScrollView(
        child: _credentials == null ? _createForm() : _credentialsForm(),
      ),
    ),
  );

  Widget _createForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('Create an administrator', style: sans(16, w: 600, tracking: -.015)),
      const SizedBox(height: 5),
      Text(
        'A strong temporary password is generated after the account is '
        'created. You can save or share the credentials once.',
        style: sans(12, height: 1.6, color: SR.ink4),
      ),
      const SizedBox(height: 16),
      const SrLabel('Email address'),
      SrTextField(
        controller: _email,
        placeholder: 'name@csu.edu.ph',
        semanticLabel: 'Email address',
        hasError: _error != null,
        keyboardType: TextInputType.emailAddress,
        onChanged: (_) {
          if (!_busy) setState(() => _error = null);
        },
      ),
      SrErrorText(_error),
      const SizedBox(height: 12),
      const SrLabel('Role'),
      for (final role in const [
        AccountRole.internalAdmin,
        AccountRole.externalAdmin,
      ])
        _RoleOption(
          role: role,
          selected: _role == role,
          onTap: () => setState(() => _role = role),
        ),
      const SizedBox(height: 12),
      SrLabel(
        'Note in the invitation',
        meta: Text('optional', style: sans(11, color: SR.muted)),
      ),
      SrTextField(
        controller: _note,
        placeholder:
            'e.g. You will handle external client bookings from August.',
        semanticLabel: 'Note in the invitation',
        fontSize: 12.5,
        minLines: 2,
        maxLines: 4,
        keyboardType: TextInputType.multiline,
      ),
      const SizedBox(height: 16),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SrButton(
            label: 'Cancel',
            fontSize: 12.5,
            minHeight: 40,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
          SrButton(
            label: _busy ? 'Creating…' : 'Create administrator',
            kind: SrButtonKind.primary,
            fontSize: 12.5,
            minHeight: 40,
            onPressed: _busy ? null : _create,
          ),
        ],
      ),
    ],
  );

  Widget _credentialsForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Administrator created', style: sans(16, w: 600, tracking: -.015)),
        const SizedBox(height: 5),
        Text(
          'Give these credentials directly to the administrator. The temporary '
          'password is shown only in this dialog.',
          style: sans(12, height: 1.6, color: SR.ink4),
        ),
        const SizedBox(height: 16),
        const SrLabel('Login email'),
        SrTextField(
          controller: _credentialEmail,
          readOnly: true,
          semanticLabel: 'Administrator login email',
        ),
        const SizedBox(height: 12),
        const SrLabel('Temporary password'),
        SrTextField(
          controller: _credentialPassword,
          readOnly: true,
          mono: true,
          semanticLabel: 'Administrator temporary password',
        ),
        const SizedBox(height: 10),
        _CredentialWarning(),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SrButton(
              label: _busy ? 'Saving…' : 'Save credentials file',
              kind: SrButtonKind.primary,
              fontSize: 12.5,
              minHeight: 40,
              onPressed: _busy ? null : _saveCredentials,
            ),
            SrButton(
              label: kIsWeb
                  ? 'Sharing unavailable on web'
                  : (_busy ? 'Working…' : 'Share credentials'),
              fontSize: 12.5,
              minHeight: 40,
              onPressed: kIsWeb || _busy ? null : _shareCredentials,
            ),
          ],
        ),
        SrErrorText(_error),
        if (_notice != null) ...[
          const SizedBox(height: 8),
          Text(_notice!, style: sans(11.5, color: SR.greenDark)),
        ],
        const SizedBox(height: 14),
        SrButton(
          label: 'Done',
          expand: true,
          minHeight: 40,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _CredentialWarning extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: SR.amberTint,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: SR.amberLine),
    ),
    child: Text(
      'Save or share this only through a secure channel. Ask the new '
      'administrator to change the temporary password after their first sign-in.',
      style: sans(11, height: 1.5, color: SR.amberTitle),
    ),
  );
}

class _RoleOption extends StatelessWidget {
  const _RoleOption({
    required this.role,
    required this.selected,
    required this.onTap,
  });

  final AccountRole role;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      button: true,
      selected: selected,
      child: Hoverable(
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: SR.stateChange,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
              color: selected ? SR.blueTint : SR.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? SR.blue : (hovered ? SR.blueSoft : SR.border),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  margin: const EdgeInsets.only(top: 2),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? SR.blue : SR.borderField,
                    ),
                  ),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: selected ? SR.blue : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(role.label, style: sans(12.5, w: 600)),
                      const SizedBox(height: 2),
                      Text(
                        role.privileges,
                        style: sans(11, height: 1.55, color: SR.ink4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
