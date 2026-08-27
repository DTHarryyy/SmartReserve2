import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_state.dart';
import '../../model/account.dart';
import '../../model/notice.dart';
import '../../theme/sr_tokens.dart';
import '../../util/file_export.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_controls.dart';

import '../../theme/sr_theme.dart';

Future<void> showInviteDialog(BuildContext context, AppState state) =>
    showDialog<void>(
      context: context,
      barrierColor: context.srColors.scrim,
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

  Future<void> _saveCredentials() => _export(
    () async {
      final result = await saveTextFile(
        baseName: 'smartreserve-admin-credentials',
        extension: 'txt',
        contents: _credentials!.exportText,
      );
      if (!result.ok) throw Exception(result.error);
      _notice =
          'Credentials file saved to ${result.path}. Keep it in a secure location.';
    },
    toast: 'Credentials file wasn’t saved.',
    detail:
        'Credentials could not be saved. Check download permissions and try again.',
  );

  Future<void> _shareCredentials() => _export(
    () async {
      await SharePlus.instance.share(
        ShareParams(
          title: 'SmartReserve administrator credentials',
          subject: 'SmartReserve administrator credentials',
          text: _credentials!.exportText,
        ),
      );
      _notice = 'Credentials were sent to the share sheet.';
    },
    toast: 'Credentials weren’t shared.',
    detail:
        'Credentials could not be shared. Check sharing permissions and try again.',
  );

  Future<void> _export(
    Future<void> Function() action, {
    required String toast,
    required String detail,
  }) async {
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
          _error = detail;
        });
        widget.state.showToast(
          ToastMessage(toast, tone: AdvisoryTone.block),
          duration: const Duration(seconds: 6),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => SrAdaptiveDialog(
    maxWidth: 460,
    maxHeight: 720,
    padding: EdgeInsets.all(
      SR.isCompact(MediaQuery.sizeOf(context).width) ? 16 : 22,
    ),
    child: SingleChildScrollView(
      child: _credentials == null ? _createForm() : _credentialsForm(),
    ),
  );

  Widget _createForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('Create an administrator', style: SrType.heading()),
      const SizedBox(height: SR.space4 + 1),
      Text(
        'A strong temporary password is generated after the account is '
        'created. You can save or share the credentials once.',
        style: SrType.bodySm(color: context.srColors.ink4),
      ),
      const SizedBox(height: SR.space16),
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
      const SizedBox(height: SR.space12),
      const SrLabel('Role'),
      for (final role in const [
        AccountRole.internalAdmin,
        AccountRole.externalAdmin,
      ])
        _RoleOption(
          role: role,
          selected: _role == role,
          onTap: () => setState(() {
            _role = role;
            _error = null;
          }),
        ),
      const SizedBox(height: SR.space12),
      SrLabel(
        'Note in the invitation',
        meta: Text('optional', style: SrType.caption()),
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
        onChanged: (_) {
          if (!_busy && _error != null) setState(() => _error = null);
        },
      ),
      const SizedBox(height: SR.space16),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SrButton(
            label: 'Cancel',
            fontSize: 12.5,
            minHeight: 40,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: SR.space8),
          Flexible(
            child: SrButton(
              label: _busy ? 'Creating…' : 'Create administrator',
              icon: _busy
                  ? null
                  : const Icon(
                      Icons.person_add_alt_1_rounded,
                      size: SR.iconSm,
                      color: SR.onDark,
                    ),
              kind: SrButtonKind.primary,
              fontSize: 12.5,
              minHeight: 40,
              onPressed: _busy ? null : _create,
            ),
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
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              margin: const EdgeInsets.only(right: SR.space8, top: 1),
              decoration: BoxDecoration(
                color: context.srColors.greenTint,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_rounded,
                size: 16,
                color: context.srColors.greenDark,
              ),
            ),
            Expanded(
              child: Text('Administrator created', style: SrType.heading()),
            ),
          ],
        ),
        const SizedBox(height: SR.space4 + 1),
        Text(
          'Give these credentials directly to the administrator. The temporary '
          'password is shown only in this dialog.',
          style: SrType.bodySm(color: context.srColors.ink4),
        ),
        const SizedBox(height: SR.space16),
        const SrLabel('Login email'),
        SrTextField(
          controller: _credentialEmail,
          readOnly: true,
          semanticLabel: 'Administrator login email',
        ),
        const SizedBox(height: SR.space12),
        const SrLabel('Temporary password'),
        SrTextField(
          controller: _credentialPassword,
          readOnly: true,
          mono: true,
          semanticLabel: 'Administrator temporary password',
        ),
        const SizedBox(height: SR.space8 + 2),
        _CredentialWarning(),
        const SizedBox(height: SR.space12 + 2),
        Wrap(
          spacing: SR.space8,
          runSpacing: SR.space8,
          children: [
            SrButton(
              label: _busy ? 'Saving…' : 'Save credentials file',
              icon: _busy
                  ? null
                  : const Icon(
                      Icons.download_rounded,
                      size: SR.iconSm,
                      color: SR.onDark,
                    ),
              kind: SrButtonKind.primary,
              fontSize: 12.5,
              minHeight: 40,
              onPressed: _busy ? null : _saveCredentials,
            ),
            SrButton(
              label: kIsWeb
                  ? 'Sharing unavailable on web'
                  : (_busy ? 'Working…' : 'Share credentials'),
              icon: kIsWeb || _busy
                  ? null
                  : Icon(
                      Icons.ios_share_rounded,
                      size: SR.iconSm,
                      color: context.srColors.ink3,
                    ),
              fontSize: 12.5,
              minHeight: 40,
              onPressed: kIsWeb || _busy ? null : _shareCredentials,
            ),
          ],
        ),
        SrErrorText(_error),
        if (_notice != null) ...[
          const SizedBox(height: SR.space8),
          Text(
            _notice!,
            style: SrType.bodySm(color: context.srColors.greenDark),
          ),
        ],
        const SizedBox(height: SR.space12 + 2),
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
    padding: const EdgeInsets.all(SR.space12 - 1),
    decoration: BoxDecoration(
      color: SrTone.warning.tint,
      borderRadius: BorderRadius.circular(SR.rSm + 1),
      border: Border.all(color: SrTone.warning.line),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.warning_amber_rounded,
          size: SR.iconSm,
          color: SrTone.warning.ink,
        ),
        const SizedBox(width: SR.space8),
        Expanded(
          child: Text(
            'Save or share this only through a secure channel. Ask the new '
            'administrator to change the temporary password after their '
            'first sign-in.',
            style: SrType.caption(color: SrTone.warning.ink),
          ),
        ),
      ],
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
    padding: const EdgeInsets.only(bottom: SR.space8),
    child: Semantics(
      button: true,
      selected: selected,
      child: Hoverable(
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: SR.stateChange,
            padding: const EdgeInsets.symmetric(
              horizontal: SR.space12 + 1,
              vertical: SR.space12,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? context.srColors.primaryTint
                  : context.srColors.surface,
              borderRadius: BorderRadius.circular(SR.rMd - 2),
              border: Border.all(
                color: selected
                    ? SR.primary
                    : (hovered
                          ? context.srColors.primarySoft
                          : context.srColors.border),
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
                      color: selected
                          ? SR.primary
                          : context.srColors.borderField,
                    ),
                  ),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: selected ? SR.primary : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: SR.space8 + 3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        role.label,
                        style: SrType.body(w: 600, color: context.srColors.ink),
                      ),
                      const SizedBox(height: SR.space2),
                      Text(role.privileges, style: SrType.caption()),
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
