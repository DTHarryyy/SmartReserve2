import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_state.dart';
import '../../model/account.dart';
import '../../model/notice.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/file_export.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';

Future<void> showOrganizationAccountsDialog(
  BuildContext context,
  AppState state,
) {
  if (state.isInternalAdmin) {
    unawaited(state.refreshOrganizationRegistry());
  }
  return showDialog<void>(
    context: context,
    barrierColor: context.srColors.scrim,
    builder: (_) => _OrganizationAccountsDialog(state: state),
  );
}

class _OrganizationAccountsDialog extends StatefulWidget {
  const _OrganizationAccountsDialog({required this.state});

  final AppState state;

  @override
  State<_OrganizationAccountsDialog> createState() =>
      _OrganizationAccountsDialogState();
}

class _OrganizationAccountsDialogState
    extends State<_OrganizationAccountsDialog> {
  static const _targetAccounts = 9;
  static const _unitTypes = [
    'college',
    'student_organization',
    'department',
    'office',
    'dean_office',
  ];
  static const _audiences = ['student', 'faculty', 'staff'];

  final _unitName = TextEditingController();
  final _unitCode = TextEditingController();
  final _repName = TextEditingController();
  final _repEmail = TextEditingController();
  final _credentialEmail = TextEditingController();
  final _credentialPassword = TextEditingController();
  String _unitType = 'student_organization';
  String _audience = 'student';
  bool _requiresRepresentative = true;
  OrganizationUnit? _parent;
  OrganizationAccountSlot? _selectedSlot;
  Account? _transferReplacement;
  AccountCredentials? _credentials;
  String? _error;
  String? _notice;
  bool _busy = false;

  @override
  void dispose() {
    _unitName.dispose();
    _unitCode.dispose();
    _repName.dispose();
    _repEmail.dispose();
    _credentialEmail.dispose();
    _credentialPassword.dispose();
    super.dispose();
  }

  AppState get _state => widget.state;

  List<OrganizationUnit> get _units => [
    ..._state.organizationUnits,
  ]..sort((a, b) {
    final policy = (a.requiresRepresentative ? 1 : 0)
        .compareTo(b.requiresRepresentative ? 1 : 0);
    if (policy != 0) return policy;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  List<OrganizationUnit> get _containers => [
    for (final unit in _state.organizationUnits)
      if (unit.active && !unit.requiresRepresentative) unit,
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  List<OrganizationAccountSlot> get _slots => [
    ..._state.organizationSlots,
  ]..sort((a, b) {
    final aName = a.unit?.name ?? a.label;
    final bName = b.unit?.name ?? b.label;
    return aName.toLowerCase().compareTo(bName.toLowerCase());
  });

  int get _configuredAccounts =>
      _slots.where((slot) => slot.active && (slot.unit?.active ?? true)).length;

  OrganizationAccountSlot? _slotForUnit(OrganizationUnit unit) {
    for (final slot in _slots) {
      if (slot.unitId == unit.id && slot.active) return slot;
    }
    return null;
  }

  Account? _accountForSlot(OrganizationAccountSlot slot) {
    final id = slot.assignedProfileId;
    if (id == null) return null;
    for (final account in _state.accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  List<Account> get _transferCandidates => [
    for (final account in _state.accounts)
      if (account.role == AccountRole.user &&
          account.status == AccountStatus.active &&
          account.isLegacyUnassigned &&
          !account.hasOrganizationSlot)
        account,
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Future<void> _perform(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final error = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  Future<void> _createUnit() async {
    await _perform(() async {
      final error = await _state.saveOrganizationUnit(
        parentId: _parent?.id,
        name: _unitName.text,
        code: _unitCode.text,
        unitType: _unitType,
        requiresRepresentative: _requiresRepresentative,
        bookingAudience: _requiresRepresentative ? _audience : null,
      );
      if (error == null) {
        _unitName.clear();
        _unitCode.clear();
        _parent = null;
        _notice = 'Organization saved.';
      }
      return error;
    });
  }

  Future<void> _createRepresentative() async {
    final slot = _selectedSlot;
    if (slot == null) {
      setState(() => _error = 'Choose a vacant organization slot.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final result = await _state.createOrganizationRepresentative(
      fullName: _repName.text,
      email: _repEmail.text,
      slotId: slot.id,
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
      _repName.clear();
      _repEmail.clear();
      _selectedSlot = null;
    });
  }

  Future<void> _resetPassword(Account account) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final result = await _state.resetOrganizationRepresentativePassword(account);
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

  Future<void> _removeRepresentative(Account account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SrConfirmDialog(
        title: 'Remove representative?',
        content: Text(
          '${account.name} will keep their login but lose organization booking access.',
        ),
        cancelLabel: 'Keep representative',
        confirmLabel: 'Remove',
        destructive: true,
        onCancel: () => Navigator.of(dialogContext).pop(false),
        onConfirm: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform(() => _state.removeOrganizationRepresentative(account.id));
  }

  Future<void> _transferRepresentative(
    OrganizationAccountSlot slot,
    Account current,
  ) async {
    final replacement = _transferReplacement;
    if (replacement == null) {
      setState(() => _error = 'Choose a replacement account first.');
      return;
    }
    await _perform(
      () => _state.transferOrganizationRepresentative(
        currentProfileId: current.id,
        replacementProfileId: replacement.id,
        slotId: slot.id,
      ),
    );
    if (mounted && _error == null) setState(() => _transferReplacement = null);
  }

  Future<void> _copyCredentials() async {
    final credentials = _credentials;
    if (credentials == null) return;
    await Clipboard.setData(ClipboardData(text: credentials.exportText));
    setState(() => _notice = 'Credentials copied.');
  }

  Future<void> _saveCredentials() async {
    final credentials = _credentials;
    if (credentials == null) return;
    await _export(
      () async {
        final result = await saveTextFile(
          baseName: 'smartreserve-organization-credentials',
          extension: 'txt',
          contents: credentials.exportText,
        );
        if (!result.ok) throw Exception(result.error);
        _notice = 'Credentials file saved to ${result.path}.';
      },
      toast: 'Credentials file was not saved.',
      detail: 'Credentials could not be saved. Check download permissions.',
    );
  }

  Future<void> _shareCredentials() async {
    final credentials = _credentials;
    if (credentials == null) return;
    await _export(
      () async {
        await SharePlus.instance.share(
          ShareParams(
            title: 'SmartReserve organization representative credentials',
            subject: 'SmartReserve organization representative credentials',
            text: credentials.exportText,
          ),
        );
        _notice = 'Credentials were sent to the share sheet.';
      },
      toast: 'Credentials were not shared.',
      detail: 'Credentials could not be shared on this device.',
    );
  }

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
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = detail;
      });
      _state.showToast(
        ToastMessage(toast, tone: AdvisoryTone.block),
        duration: const Duration(seconds: 6),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _state,
    builder: (context, _) => SrAdaptiveDialog(
      maxWidth: 880,
      maxHeight: 820,
      padding: EdgeInsets.all(
        SR.isCompact(MediaQuery.sizeOf(context).width) ? 16 : 22,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Organization accounts', style: SrType.heading()),
                      const SizedBox(height: 5),
                      Text(
                        'One named representative account per organization. Direct temporary credentials only.',
                        style: SrType.bodySm(color: context.srColors.ink4),
                      ),
                    ],
                  ),
                ),
                SrButton(
                  label: 'Close',
                  dense: true,
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: SR.space16),
            _progressCard(),
            const SizedBox(height: SR.space12),
            if (_credentials != null) ...[
              _credentialsCard(),
              const SizedBox(height: SR.space12),
            ],
            if (_state.organizationRegistryError != null) ...[
              SrErrorText(_state.organizationRegistryError),
              const SizedBox(height: SR.space12),
            ],
            _setupCard(),
            const SizedBox(height: SR.space12),
            _representativeForm(),
            const SizedBox(height: SR.space12),
            _registryList(),
            SrErrorText(_error),
            if (_notice != null) ...[
              const SizedBox(height: SR.space8),
              Text(
                _notice!,
                style: SrType.bodySm(color: context.srColors.greenDark),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _progressCard() {
    final count = _configuredAccounts.clamp(0, _targetAccounts);
    final progress = count / _targetAccounts;
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$count of $_targetAccounts organization accounts configured',
                  style: SrType.body(w: 600),
                ),
              ),
              SrStatusChip(
                label: count == _targetAccounts ? 'Complete' : 'Setup needed',
                tone: count == _targetAccounts
                    ? SrTone.success
                    : SrTone.warning,
              ),
            ],
          ),
          const SizedBox(height: SR.space8),
          ClipRRect(
            borderRadius: BorderRadius.circular(SR.rXs),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: context.srColors.hairline,
              color: SR.primary,
            ),
          ),
          const SizedBox(height: SR.space8),
          Text(
            'Create CICS and COLSC as containers, then add seven CICS/COLSC organization accounts plus the Dean Office account.',
            style: SrType.caption(),
          ),
        ],
      ),
    );
  }

  Widget _credentialsCard() => SrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.vpn_key_rounded, size: 18, color: context.srColors.greenDark),
            const SizedBox(width: SR.space8),
            Expanded(
              child: Text('Temporary credentials', style: SrType.body(w: 600)),
            ),
            SrButton(
              label: 'Hide',
              dense: true,
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _credentials = null;
                      _credentialEmail.clear();
                      _credentialPassword.clear();
                    }),
            ),
          ],
        ),
        const SizedBox(height: SR.space12),
        const SrLabel('Login email'),
        SrTextField(controller: _credentialEmail, readOnly: true),
        const SizedBox(height: SR.space8),
        const SrLabel('Temporary password'),
        SrTextField(controller: _credentialPassword, readOnly: true, mono: true),
        const SizedBox(height: SR.space8),
        Text(
          'Show this directly to the named representative. It appears here once and must be changed at first sign-in.',
          style: SrType.caption(color: SrTone.warning.ink),
        ),
        const SizedBox(height: SR.space12),
        Wrap(
          spacing: SR.space8,
          runSpacing: SR.space8,
          children: [
            SrButton(
              label: 'Copy',
              icon: const Icon(Icons.copy_rounded, size: SR.iconSm),
              onPressed: _busy ? null : _copyCredentials,
            ),
            SrButton(
              label: _busy ? 'Saving...' : 'Save credentials file',
              icon: _busy
                  ? null
                  : const Icon(Icons.download_rounded, size: SR.iconSm),
              kind: SrButtonKind.primary,
              onPressed: _busy ? null : _saveCredentials,
            ),
            SrButton(
              label: kIsWeb ? 'Sharing unavailable' : 'Share',
              icon: kIsWeb
                  ? null
                  : const Icon(Icons.ios_share_rounded, size: SR.iconSm),
              onPressed: kIsWeb || _busy ? null : _shareCredentials,
            ),
          ],
        ),
      ],
    ),
  );

  Widget _setupCard() => SrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Add organization unit', style: SrType.body(w: 600)),
        const SizedBox(height: SR.space4),
        Text(
          'Use containers for CICS and COLSC. Account-bearing units automatically receive exactly one representative slot.',
          style: SrType.caption(),
        ),
        const SizedBox(height: SR.space12),
        Wrap(
          spacing: SR.space12,
          runSpacing: SR.space12,
          children: [
            SizedBox(
              width: 250,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SrLabel('Organization name'),
                  SrTextField(
                    controller: _unitName,
                    placeholder: 'e.g. CICS Student Council',
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 150,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SrLabel(
                    'Code',
                    meta: Text('optional', style: SrType.caption()),
                  ),
                  SrTextField(controller: _unitCode, placeholder: 'e.g. CICS'),
                ],
              ),
            ),
            SizedBox(
              width: 190,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SrLabel('Type'),
                  SrSelect<String>(
                    value: _unitType,
                    items: _unitTypes,
                    labelOf: _unitTypeLabel,
                    onChanged: _busy
                        ? (_) {}
                        : (value) => setState(() {
                            _unitType = value ?? _unitType;
                            if (_unitType == 'college') {
                              _requiresRepresentative = false;
                            }
                            if (_unitType == 'dean_office') {
                              _requiresRepresentative = true;
                              _parent = null;
                            }
                          }),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 210,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SrLabel(
                    'Parent',
                    meta: _parent == null
                        ? Text('none', style: SrType.caption())
                        : null,
                  ),
                  SrSelect<OrganizationUnit>(
                    value: _parent,
                    items: _containers,
                    placeholder: 'No parent',
                    labelOf: (unit) => unit.label,
                    onChanged: _busy
                        ? (_) {}
                        : (value) => setState(() => _parent = value),
                  ),
                  if (_parent != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _InlineAction(
                        label: 'Clear parent',
                        onTap: () => setState(() => _parent = null),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: _requiresRepresentative,
          onChanged: _unitType == 'college' || _busy
              ? null
              : (value) => setState(
                  () => _requiresRepresentative = value ?? true,
                ),
          title: Text('This unit receives one representative account', style: SrType.bodySm()),
          subtitle: Text(
            'Turn off only for hierarchy containers such as CICS or COLSC.',
            style: SrType.caption(),
          ),
        ),
        if (_requiresRepresentative) ...[
          const SizedBox(height: SR.space8),
          const SrLabel('Booking audience'),
          SrSelect<String>(
            value: _audience,
            items: _audiences,
            labelOf: OrganizationUnit.audienceLabel,
            onChanged: _busy
                ? (_) {}
                : (value) => setState(() => _audience = value ?? _audience),
          ),
        ],
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: SrButton(
            label: _busy ? 'Saving...' : 'Save organization',
            icon: _busy
                ? null
                : const Icon(Icons.add_business_rounded, size: SR.iconSm),
            kind: SrButtonKind.primary,
            onPressed: _busy ? null : _createUnit,
          ),
        ),
      ],
    ),
  );

  Widget _representativeForm() {
    final slot = _selectedSlot;
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Create representative account', style: SrType.body(w: 600)),
          const SizedBox(height: SR.space4),
          Text(
            slot == null
                ? 'Choose a vacant account-bearing organization below.'
                : '${slot.unit?.label ?? slot.label} · ${OrganizationUnit.audienceLabel(slot.unit?.bookingAudience)}',
            style: SrType.caption(),
          ),
          const SizedBox(height: SR.space12),
          Wrap(
            spacing: SR.space12,
            runSpacing: SR.space12,
            children: [
              SizedBox(
                width: 260,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SrLabel('Full name'),
                    SrTextField(
                      controller: _repName,
                      placeholder: 'Named representative',
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 260,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SrLabel('Email address'),
                    SrTextField(
                      controller: _repEmail,
                      placeholder: 'representative@example.com',
                      keyboardType: TextInputType.emailAddress,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: SrButton(
              label: _busy ? 'Creating...' : 'Create account',
              icon: _busy
                  ? null
                  : const Icon(Icons.person_add_alt_1_rounded, size: SR.iconSm),
              kind: SrButtonKind.primary,
              onPressed: _busy || slot == null ? null : _createRepresentative,
            ),
          ),
        ],
      ),
    );
  }

  Widget _registryList() => SrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Registry', style: SrType.body(w: 600))),
            if (_state.organizationRegistryLoading)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.srColors.muted,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (_units.isEmpty)
          Text(
            'No organizations configured yet.',
            style: SrType.bodySm(color: context.srColors.ink4),
          )
        else
          for (final unit in _units) _unitRow(unit),
      ],
    ),
  );

  Widget _unitRow(OrganizationUnit unit) {
    final slot = _slotForUnit(unit);
    final account = slot == null ? null : _accountForSlot(slot);
    return Container(
      margin: const EdgeInsets.only(bottom: SR.space8),
      padding: const EdgeInsets.all(SR.space12),
      decoration: BoxDecoration(
        color: context.srColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(SR.rSm),
        border: Border.all(color: context.srColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(unit.label, style: SrType.body(w: 600)),
                    const SizedBox(height: 2),
                    Text(
                      '${_unitTypeLabel(unit.unitType)} · ${unit.policyLabel}',
                      style: SrType.caption(),
                    ),
                  ],
                ),
              ),
              SrStatusChip(
                label: !unit.active
                    ? 'Archived'
                    : !unit.requiresRepresentative
                    ? 'Container'
                    : slot?.assigned == true
                    ? 'Assigned'
                    : 'Vacant',
                tone: !unit.active
                    ? SrTone.neutral
                    : !unit.requiresRepresentative
                    ? SrTone.warning
                    : slot?.assigned == true
                    ? SrTone.success
                    : SrTone.warning,
              ),
            ],
          ),
          if (slot != null) ...[
            const SizedBox(height: 10),
            Text(
              account == null
                  ? 'No representative assigned.'
                  : '${account.name} · ${account.email}${account.mustChangePassword ? ' · password change required' : ''}',
              style: SrType.bodySm(color: context.srColors.ink4),
            ),
            const SizedBox(height: 10),
            if (account == null)
              Align(
                alignment: Alignment.centerLeft,
                child: SrButton(
                  label: 'Create account',
                  dense: true,
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: SR.iconSm),
                  kind: SrButtonKind.primary,
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _selectedSlot = slot;
                          _error = null;
                        }),
                ),
              )
            else
              _assignedActions(slot, account),
          ],
        ],
      ),
    );
  }

  Widget _assignedActions(OrganizationAccountSlot slot, Account account) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: SR.space8,
        runSpacing: SR.space8,
        children: [
          SrButton(
            label: 'Reset temporary password',
            dense: true,
            onPressed: _busy ? null : () => _resetPassword(account),
          ),
          SrButton(
            label: 'Remove representative',
            dense: true,
            kind: SrButtonKind.danger,
            onPressed: _busy ? null : () => _removeRepresentative(account),
          ),
        ],
      ),
      if (_transferCandidates.isNotEmpty) ...[
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: SrSelect<Account>(
                value: _transferReplacement,
                items: _transferCandidates,
                placeholder: 'Replacement account',
                labelOf: (candidate) => '${candidate.name} · ${candidate.email}',
                onChanged: _busy
                    ? (_) {}
                    : (value) =>
                        setState(() => _transferReplacement = value),
              ),
            ),
            const SizedBox(width: SR.space8),
            SrButton(
              label: 'Transfer',
              dense: true,
              onPressed: _busy
                  ? null
                  : () => _transferRepresentative(slot, account),
            ),
          ],
        ),
      ],
    ],
  );

  static String _unitTypeLabel(String value) => switch (value) {
    'college' => 'College container',
    'student_organization' => 'Student organization',
    'department' => 'Department',
    'office' => 'Office',
    'dean_office' => 'Dean Office',
    _ => value,
  };
}

class _InlineAction extends StatelessWidget {
  const _InlineAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Hoverable(
    builder: (context, hovered) => GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          label,
          style: SrType.caption(
            color: hovered ? context.srColors.ink3 : context.srColors.muted,
          ).copyWith(decoration: TextDecoration.underline),
        ),
      ),
    ),
  );
}
