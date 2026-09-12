import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/account.dart';
import '../../model/notice.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/file_export.dart';
import '../../widgets/record_table.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';

class OrganizationsScreen extends StatefulWidget {
  const OrganizationsScreen({super.key});

  @override
  State<OrganizationsScreen> createState() => _OrganizationsScreenState();
}

class _OrganizationsScreenState extends State<OrganizationsScreen> {
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
  void initState() {
    super.initState();
    final state = AppScope.read(context);
    if (state.isInternalAdmin) state.refreshOrganizationRegistry();
  }

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

  AppState get _state => AppScope.of(context);

  List<OrganizationUnit> get _units =>
      [..._state.organizationUnits]..sort((a, b) {
        final policy = (a.requiresRepresentative ? 1 : 0).compareTo(
          b.requiresRepresentative ? 1 : 0,
        );
        if (policy != 0) return policy;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

  List<OrganizationUnit> get _containers => [
    for (final unit in _state.organizationUnits)
      if (unit.active && !unit.requiresRepresentative) unit,
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  List<OrganizationAccountSlot> get _slots =>
      [..._state.organizationSlots]..sort((a, b) {
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

  Future<bool> _perform(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final error = await action();
    if (!mounted) return false;
    setState(() {
      _busy = false;
      _error = error;
    });
    return error == null;
  }

  Future<bool> _createUnit() async {
    return _perform(() async {
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

  Future<bool> _createRepresentative() async {
    final slot = _selectedSlot;
    if (slot == null) {
      setState(() => _error = 'Choose a vacant organization slot.');
      return false;
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
    if (!mounted) return false;
    if (result.error != null) {
      setState(() {
        _busy = false;
        _error = result.error;
      });
      return false;
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
    return true;
  }

  Future<void> _resetPassword(Account account) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final result = await _state.resetOrganizationRepresentativePassword(
      account,
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
    builder: (context, _) {
      if (!_state.isInternalAdmin) {
        return Center(
          child: Text(
            'Organization management is restricted to Internal Admins.',
            style: SrType.bodySm(color: context.srColors.muted),
          ),
        );
      }
      final width = MediaQuery.sizeOf(context).width;
      final compact = SR.isCompact(width);
      return SrScrollView(
        padding: SR.pageInsets(width, top: compact ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SrPageHeader(
              title: 'Organizations',
              description:
                  '${_units.length} organization${_units.length == 1 ? '' : 's'} configured',
              actions: compact ? const [] : _pageActions(),
            ),
            if (compact) ...[
              const SizedBox(height: SR.space12),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: SR.space8,
                  runSpacing: SR.space8,
                  alignment: WrapAlignment.end,
                  children: _pageActions(),
                ),
              ),
            ],
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
            _registryTable(),
            if (_error != null) ...[
              const SizedBox(height: SR.space12),
              SrErrorText(_error),
            ],
            if (_notice != null) ...[
              const SizedBox(height: SR.space8),
              Text(
                _notice!,
                style: SrType.bodySm(color: context.srColors.greenDark),
              ),
            ],
          ],
        ),
      );
    },
  );

  List<Widget> _pageActions() => [
    SrButton(
      label: 'Add organization',
      icon: const Icon(Icons.add_business_rounded, size: SR.iconSm),
      onPressed: _busy ? null : _showOrganizationDialog,
    ),
    SrButton(
      label: 'Create representative account',
      icon: const Icon(Icons.person_add_alt_1_rounded, size: SR.iconSm),
      kind: SrButtonKind.primary,
      onPressed: _busy ? null : _showRepresentativeDialog,
    ),
  ];

  Future<void> _showOrganizationDialog() => showDialog<void>(
    context: context,
    barrierColor: context.srColors.scrim,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => SrAdaptiveDialog(
        maxWidth: 760,
        maxHeight: 760,
        padding: const EdgeInsets.all(SR.space20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _dialogHeader('Add organization', dialogContext),
              const SizedBox(height: SR.space16),
              _setupCard(
                onSaved: () async {
                  final saved = await _createUnit();
                  if (!mounted) return;
                  setDialogState(() {});
                  if (saved && dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: SR.space12),
                SrErrorText(_error),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _showRepresentativeDialog([OrganizationAccountSlot? slot]) {
    setState(() {
      _selectedSlot = slot;
      _error = null;
    });
    return showDialog<void>(
      context: context,
      barrierColor: context.srColors.scrim,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => SrAdaptiveDialog(
          maxWidth: 660,
          maxHeight: 680,
          padding: const EdgeInsets.all(SR.space20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _dialogHeader('Create representative account', dialogContext),
                const SizedBox(height: SR.space16),
                _representativeForm(
                  onChanged: () => setDialogState(() {}),
                  onCreated: () async {
                    final created = await _createRepresentative();
                    if (!mounted) return;
                    setDialogState(() {});
                    if (created && dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: SR.space12),
                  SrErrorText(_error),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showTransferDialog(
    OrganizationAccountSlot slot,
    Account account,
  ) {
    setState(() {
      _transferReplacement = null;
      _error = null;
    });
    return showDialog<void>(
      context: context,
      barrierColor: context.srColors.scrim,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => SrAdaptiveDialog(
          maxWidth: 520,
          maxHeight: 440,
          padding: const EdgeInsets.all(SR.space20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogHeader('Transfer representative', dialogContext),
              const SizedBox(height: SR.space8),
              Text(
                'Choose an active, unassigned account to represent ${slot.unit?.label ?? slot.label}.',
                style: SrType.bodySm(),
              ),
              const SizedBox(height: SR.space16),
              const SrLabel('Replacement account'),
              SrSelect<Account>(
                value: _transferReplacement,
                items: _transferCandidates,
                placeholder: 'Choose an account',
                labelOf: (candidate) =>
                    '${candidate.name} · ${candidate.email}',
                onChanged: _busy
                    ? (_) {}
                    : (value) {
                        setState(() => _transferReplacement = value);
                        setDialogState(() {});
                      },
              ),
              if (_error != null) ...[
                const SizedBox(height: SR.space12),
                SrErrorText(_error),
              ],
              const SizedBox(height: SR.space20),
              Align(
                alignment: Alignment.centerRight,
                child: SrButton(
                  label: _busy ? 'Transferring...' : 'Transfer',
                  kind: SrButtonKind.primary,
                  onPressed: _busy || _transferReplacement == null
                      ? null
                      : () async {
                          await _transferRepresentative(slot, account);
                          if (!mounted) return;
                          setDialogState(() {});
                          if (_error == null && dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                        },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dialogHeader(String title, BuildContext dialogContext) => Row(
    children: [
      Expanded(child: Text(title, style: SrType.heading())),
      SrIconButton(
        icon: Icons.close_rounded,
        tooltip: 'Close',
        onPressed: _busy ? null : () => Navigator.of(dialogContext).pop(),
      ),
    ],
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
            Icon(
              Icons.vpn_key_rounded,
              size: 18,
              color: context.srColors.greenDark,
            ),
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
        SrTextField(
          controller: _credentialPassword,
          readOnly: true,
          mono: true,
        ),
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

  Widget _setupCard({required Future<void> Function() onSaved}) => SrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
              : (value) =>
                    setState(() => _requiresRepresentative = value ?? true),
          title: Text(
            'This unit receives one representative account',
            style: SrType.bodySm(),
          ),
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
            label: _busy ? 'Saving...' : 'Add organization',
            icon: _busy
                ? null
                : const Icon(Icons.add_business_rounded, size: SR.iconSm),
            kind: SrButtonKind.primary,
            onPressed: _busy ? null : onSaved,
          ),
        ),
      ],
    ),
  );

  Widget _representativeForm({
    required VoidCallback onChanged,
    required Future<void> Function() onCreated,
  }) {
    final slot = _selectedSlot;
    return SrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            slot == null
                ? 'Choose a vacant account-bearing organization.'
                : '${slot.unit?.label ?? slot.label} · ${OrganizationUnit.audienceLabel(slot.unit?.bookingAudience)}',
            style: SrType.caption(),
          ),
          const SizedBox(height: SR.space12),
          const SrLabel('Organization'),
          SrSelect<OrganizationAccountSlot>(
            value: slot,
            items: [
              for (final candidate in _slots)
                if (candidate.active &&
                    (candidate.unit?.active ?? true) &&
                    !candidate.assigned)
                  candidate,
            ],
            placeholder: 'Choose an organization',
            labelOf: (candidate) => candidate.unit?.label ?? candidate.label,
            onChanged: _busy
                ? (_) {}
                : (value) {
                    setState(() => _selectedSlot = value);
                    onChanged();
                  },
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
              onPressed: _busy || slot == null ? null : onCreated,
            ),
          ),
        ],
      ),
    );
  }

  static const _registryColumns = [
    ColSpec('ORGANIZATION', flex: 3),
    ColSpec('PARENT', flex: 2, hide: ColumnHide.small),
    ColSpec('REPRESENTATIVE', flex: 3, hide: ColumnHide.medium),
    ColSpec('STATUS', width: 104),
    ColSpec('ACTIONS', width: 184, alignRight: true),
  ];

  Widget _registryTable() {
    if (_state.organizationRegistryLoading && _units.isEmpty) {
      return RecordTable(
        columns: _registryColumns,
        children: [
          for (var i = 0; i < 4; i++)
            SkeletonRow(columns: _registryColumns, leadWidth: .65),
        ],
      );
    }
    if (_units.isEmpty) {
      return RecordTable(
        columns: _registryColumns,
        children: [
          ListEmptyState(
            icon: Icons.account_tree_outlined,
            title: 'No organizations yet',
            body: 'Add an organization to create its account registry entry.',
            action: SrButton(
              label: 'Add organization',
              kind: SrButtonKind.primary,
              onPressed: _showOrganizationDialog,
            ),
          ),
        ],
      );
    }
    return RecordTable(
      columns: _registryColumns,
      footerNote:
          'Each account-bearing organization has one named representative account.',
      children: [for (final unit in _units) _unitRow(unit)],
    );
  }

  String _parentLabel(OrganizationUnit unit) {
    final parentId = unit.parentId;
    if (parentId == null) return '—';
    for (final parent in _units) {
      if (parent.id == parentId) return parent.label;
    }
    return '—';
  }

  Widget _unitRow(OrganizationUnit unit) {
    final slot = _slotForUnit(unit);
    final account = slot == null ? null : _accountForSlot(slot);
    final status = !unit.active
        ? 'Archived'
        : !unit.requiresRepresentative
        ? 'Container'
        : slot?.assigned == true
        ? 'Assigned'
        : 'Vacant';
    final tone = !unit.active
        ? SrTone.neutral
        : !unit.requiresRepresentative
        ? SrTone.warning
        : slot?.assigned == true
        ? SrTone.success
        : SrTone.warning;
    final representative = account == null
        ? (slot?.assignedName ?? 'No representative assigned')
        : '${account.name}\n${account.email}${account.mustChangePassword ? ' · password change required' : ''}';
    return RecordRow(
      columns: _registryColumns,
      vertical: 14,
      cells: [
        Column(
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
        Text(_parentLabel(unit), style: SrType.bodySm()),
        Text(
          representative,
          style: SrType.bodySm(color: context.srColors.ink4),
        ),
        SrStatusChip(label: status, tone: tone, dense: true),
        _unitActions(slot, account),
      ],
    );
  }

  Widget _unitActions(OrganizationAccountSlot? slot, Account? account) {
    if (slot == null || !slot.active) {
      return Text('—', style: SrType.caption());
    }
    if (account == null) {
      return SrButton(
        label: 'Create account',
        dense: true,
        kind: SrButtonKind.primary,
        onPressed: _busy ? null : () => _showRepresentativeDialog(slot),
      );
    }
    return Wrap(
      spacing: SR.space6,
      runSpacing: SR.space6,
      alignment: WrapAlignment.end,
      children: [
        SrButton(
          label: 'Reset',
          dense: true,
          onPressed: _busy ? null : () => _resetPassword(account),
        ),
        SrButton(
          label: 'Remove',
          dense: true,
          kind: SrButtonKind.danger,
          onPressed: _busy ? null : () => _removeRepresentative(account),
        ),
        if (_transferCandidates.isNotEmpty)
          SrButton(
            label: 'Transfer',
            dense: true,
            onPressed: _busy ? null : () => _showTransferDialog(slot, account),
          ),
      ],
    );
  }

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
