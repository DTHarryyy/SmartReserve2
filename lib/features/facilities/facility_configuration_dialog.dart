import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/facility.dart';
import '../../theme/sr_tokens.dart';

import '../../theme/sr_theme.dart';

Future<void> showFacilityConfigurationDialog(
  BuildContext context, {
  required AppState state,
  required Facility facility,
}) => showDialog<void>(
  context: context,
  barrierColor: context.srColors.scrim,
  builder: (_) =>
      _FacilityConfigurationDialog(state: state, facility: facility),
);

class _AmenityEdit {
  _AmenityEdit({required this.name, required this.price});
  String name;
  String price;
}

class _FacilityConfigurationDialog extends StatefulWidget {
  const _FacilityConfigurationDialog({
    required this.state,
    required this.facility,
  });

  final AppState state;
  final Facility facility;

  @override
  State<_FacilityConfigurationDialog> createState() =>
      _FacilityConfigurationDialogState();
}

class _FacilityConfigurationDialogState
    extends State<_FacilityConfigurationDialog> {
  static const audiences = ['student', 'faculty', 'staff', 'guest'];
  late final Map<String, TextEditingController> _rates;
  late final TextEditingController _accountName;
  late final TextEditingController _accountNumber;
  late final TextEditingController _instructions;
  late final TextEditingController _depositHours;
  late final TextEditingController _balanceHours;
  late final TextEditingController _correctionHours;
  late final TextEditingController _downPaymentPercent;
  late final List<_AmenityEdit> _amenities;
  Future<List<FacilityAssignmentOption>>? _assignments;
  bool _saving = false;
  String? _error;

  Facility get facility => widget.facility;

  @override
  void initState() {
    super.initState();
    _rates = {
      for (final audience in audiences)
        audience: TextEditingController(
          text: _pesos(
            facility.audienceRates
                    .where((rate) => rate.audience == audience)
                    .map((rate) => rate.hourlyRateCentavos)
                    .firstOrNull ??
                0,
          ),
        ),
    };
    final method = facility.paymentMethods
        .where((item) => item.enabled)
        .firstOrNull;
    _accountName = TextEditingController(text: method?.accountName ?? '');
    _accountNumber = TextEditingController(text: method?.accountNumber ?? '');
    _instructions = TextEditingController(text: method?.instructions ?? '');
    _depositHours = TextEditingController(
      text: (facility.depositWindowMinutes / 60).toStringAsFixed(0),
    );
    _balanceHours = TextEditingController(
      text: (facility.balanceDueLeadMinutes / 60).toStringAsFixed(0),
    );
    _correctionHours = TextEditingController(
      text: (facility.paymentCorrectionWindowMinutes / 60).toStringAsFixed(0),
    );
    _downPaymentPercent = TextEditingController(
      text: '${facility.downPaymentPercent}',
    );
    _amenities = [
      for (final amenity in facility.amenityOptions.where(
        (item) => item.enabled,
      ))
        _AmenityEdit(name: amenity.name, price: _pesos(amenity.priceCentavos)),
    ];
    if (facility.assignmentRole == 'owner') {
      _assignments = widget.state.facilityAssignmentDirectory(facility.id);
    }
  }

  static String _pesos(int centavos) => (centavos / 100).toStringAsFixed(2);

  @override
  void dispose() {
    for (final controller in _rates.values) {
      controller.dispose();
    }
    _accountName.dispose();
    _accountNumber.dispose();
    _instructions.dispose();
    _depositHours.dispose();
    _balanceHours.dispose();
    _correctionHours.dispose();
    _downPaymentPercent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680, maxHeight: 760),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${facility.name} settings',
                    style: sans(17, w: 600),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _heading(
                    'Audience rates',
                    'Hourly PHP rate, including zero.',
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final audience in audiences)
                        SizedBox(
                          width: 145,
                          child: TextField(
                            controller: _rates[audience],
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText:
                                  '${audience[0].toUpperCase()}${audience.substring(1)} / hour',
                              prefixText: '₱',
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  _heading('Amenities', 'Only these IDs can be requested.'),
                  for (var index = 0; index < _amenities.length; index++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              initialValue: _amenities[index].name,
                              decoration: const InputDecoration(
                                labelText: 'Amenity',
                              ),
                              onChanged: (value) =>
                                  _amenities[index].name = value,
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 130,
                            child: TextFormField(
                              initialValue: _amenities[index].price,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: const InputDecoration(
                                labelText: 'Price',
                                prefixText: '₱',
                              ),
                              onChanged: (value) =>
                                  _amenities[index].price = value,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove amenity',
                            onPressed: () =>
                                setState(() => _amenities.removeAt(index)),
                            icon: const Icon(
                              Icons.remove_circle_outline_rounded,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(
                        () => _amenities.add(
                          _AmenityEdit(name: '', price: '0.00'),
                        ),
                      ),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add amenity'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _heading(
                    'GCash destination',
                    'Shown to approved requesters.',
                  ),
                  TextField(
                    controller: _accountName,
                    decoration: const InputDecoration(
                      labelText: 'Account name',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _accountNumber,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'GCash number',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _instructions,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Payment instructions',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _depositHours,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Proof deadline (hours)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _balanceHours,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Balance due before start (hours)',
                            helperText: '24 = exactly one day before start',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _correctionHours,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText:
                                'Rejected-proof correction window (hours)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _downPaymentPercent,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Down payment (%)',
                            helperText: '20–50',
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_assignments != null) ...[
                    const SizedBox(height: 22),
                    _heading(
                      'Administrators',
                      'Owners assign either lane; managers operate within their role lane.',
                    ),
                    FutureBuilder<List<FacilityAssignmentOption>>(
                      future: _assignments,
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const LinearProgressIndicator();
                        }
                        return Column(
                          children: [
                            for (final option in snapshot.data!)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(option.name),
                                subtitle: Text(
                                  '${option.adminLane} · ${option.email}',
                                ),
                                trailing: option.assignmentRole == null
                                    ? PopupMenuButton<String>(
                                        tooltip: 'Assign administrator',
                                        onSelected: (role) =>
                                            _setAssignment(option, role),
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 'manager',
                                            child: Text('Assign as manager'),
                                          ),
                                          PopupMenuItem(
                                            value: 'owner',
                                            child: Text('Assign as owner'),
                                          ),
                                        ],
                                        child: const Padding(
                                          padding: EdgeInsets.all(8),
                                          child: Text('Assign'),
                                        ),
                                      )
                                    : Wrap(
                                        spacing: 4,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(option.assignmentRole!),
                                          IconButton(
                                            tooltip: 'Remove assignment',
                                            onPressed: () =>
                                                _removeAssignment(option),
                                            icon: const Icon(
                                              Icons.link_off_rounded,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: sans(11, color: context.srColors.red)),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save settings'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _heading(String title, String caption) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: sans(13, w: 600)),
        Text(caption, style: sans(10.5, color: context.srColors.muted)),
      ],
    ),
  );

  Future<void> _save() async {
    final rates = <String, int>{};
    for (final audience in audiences) {
      final pesos = double.tryParse(_rates[audience]!.text.trim());
      if (pesos == null || pesos < 0) {
        setState(
          () => _error = 'Every audience needs a valid non-negative rate.',
        );
        return;
      }
      rates[audience] = (pesos * 100).round();
    }
    final amenities = <FacilityAmenity>[];
    for (var index = 0; index < _amenities.length; index++) {
      final edit = _amenities[index];
      final price = double.tryParse(edit.price.trim());
      if (edit.name.trim().length < 2 || price == null || price < 0) {
        setState(() => _error = 'Each amenity needs a name and valid price.');
        return;
      }
      amenities.add(
        FacilityAmenity(
          id: 'draft-$index',
          name: edit.name.trim(),
          priceCentavos: (price * 100).round(),
        ),
      );
    }
    final hours = int.tryParse(_depositHours.text.trim());
    final balanceHours = int.tryParse(_balanceHours.text.trim());
    final correctionHours = int.tryParse(_correctionHours.text.trim());
    final percent = int.tryParse(_downPaymentPercent.text.trim());
    if (hours == null ||
        hours < 1 ||
        balanceHours == null ||
        balanceHours < 1 ||
        correctionHours == null ||
        correctionHours < 1 ||
        percent == null ||
        percent < 20 ||
        percent > 50) {
      setState(
        () => _error =
            'Enter valid payment deadline values and a 20-50% down payment.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final success = await widget.state.saveFacilityConfiguration(
      FacilityConfigurationDraft(
        facilityId: facility.id,
        rates: rates,
        amenities: amenities,
        accountName: _accountName.text.trim(),
        accountNumber: _accountNumber.text.trim(),
        instructions: _instructions.text.trim(),
        depositWindowMinutes: hours * 60,
        balanceDueLeadMinutes: balanceHours * 60,
        correctionWindowMinutes: correctionHours * 60,
        downPaymentPercent: percent,
      ),
    );
    if (!mounted) return;
    if (success) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = 'Settings were not saved. Review the values and try again.';
      });
    }
  }

  Future<void> _setAssignment(
    FacilityAssignmentOption option,
    String role,
  ) async {
    await widget.state.setFacilityAssignment(
      facilityId: facility.id,
      adminId: option.adminId,
      assignmentRole: role,
    );
    if (mounted) {
      setState(() {
        _assignments = widget.state.facilityAssignmentDirectory(facility.id);
      });
    }
  }

  Future<void> _removeAssignment(FacilityAssignmentOption option) async {
    await widget.state.removeFacilityAssignment(
      facilityId: facility.id,
      adminId: option.adminId,
    );
    if (mounted) {
      setState(() {
        _assignments = widget.state.facilityAssignmentDirectory(facility.id);
      });
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
