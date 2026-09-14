import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../model/permit.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';

/// Repairs only the form rows that block one selected reservation. Broad
/// facility settings (rates, payment destination, unrelated amenities) stay
/// in Facility Management and are intentionally not shown here.
Future<bool?> showReservationPermitMappingDialog(
  BuildContext context, {
  required AppState state,
  required String requestId,
  required String facilityName,
  required PermitReadiness readiness,
}) => showDialog<bool>(
  context: context,
  barrierColor: context.srColors.scrim,
  builder: (_) => _ReservationPermitMappingDialog(
    state: state,
    requestId: requestId,
    facilityName: facilityName,
    readiness: readiness,
  ),
);

class _ReservationPermitMappingDialog extends StatefulWidget {
  const _ReservationPermitMappingDialog({
    required this.state,
    required this.requestId,
    required this.facilityName,
    required this.readiness,
  });

  final AppState state;
  final String requestId;
  final String facilityName;
  final PermitReadiness readiness;

  @override
  State<_ReservationPermitMappingDialog> createState() =>
      _ReservationPermitMappingDialogState();
}

class _ReservationPermitMappingDialogState
    extends State<_ReservationPermitMappingDialog> {
  final Map<String, String?> _selectedCodes = {};
  bool _saving = false;
  String? _error;

  List<PermitMappingRequirement> get _requirements =>
      widget.readiness.missingMappings;

  String _key(PermitMappingRequirement item) =>
      '${item.sourceKind}:${item.sourceId ?? item.label}';

  @override
  void initState() {
    super.initState();
    for (final item in _requirements.where((item) => item.canConfigure)) {
      _selectedCodes[_key(item)] = _recommendedCode(item);
    }
  }

  String? _recommendedCode(PermitMappingRequirement item) {
    if (!item.isFacility) return null;
    final label = item.label.toLowerCase();
    if (item.lane == 'internal') {
      if (label.contains('conference')) return 'conference_room';
      if (label.contains('audio visual') || label.contains('main hall')) {
        return 'audio_visual_main_hall';
      }
      // The fixed internal form has no Basketball Court row. "Others" is
      // the truthful official-form choice and writes the actual name.
      return 'other';
    }
    if (label.contains('gym') || label.contains('auditorium')) {
      return 'gym_auditorium';
    }
    if (label.contains('audio visual') || label.contains('avr')) return 'avr';
    if (label.contains('accommodation')) return 'accommodation';
    if (label.contains('love hall')) return 'love_hall';
    return 'other';
  }

  Map<String, String> _options(PermitMappingRequirement item) {
    if (item.lane == 'internal') {
      return item.isFacility
          ? {
              'audio_visual_main_hall': 'Audio Visual Room / Main Hall',
              'conference_room': 'Conference Room',
              'other': 'Other facility — prints “${item.label}”',
            }
          : const {
              'sound_system': 'Sound System',
              'overhead_projector': 'Overhead Projector',
              'lcd_accessories': 'LCD and accessories',
              'other': 'Others',
            };
    }
    return item.isFacility
        ? {
            'gym_auditorium': 'Gymnasium / Auditorium',
            'avr': 'Audio-Visual Room',
            'accommodation': 'Accommodation',
            'love_hall': 'Love Hall',
            'other': 'Other facility — prints “${item.label}”',
          }
        : const {
            'tables_chairs': 'Tables and chairs',
            'lcd_projector': 'LCD projector',
            'avr': 'Audio-Visual Room',
            'led_video_wall': 'LED video wall',
            'accommodation': 'Accommodation',
            'love_hall': 'Love Hall',
            'other': 'Others',
          };
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 580, maxHeight: 680),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Complete required permit mappings',
                    style: SrType.subhead(),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(SR.space20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.facilityName} needs ${_requirements.length} ${_requirements.length == 1 ? 'mapping' : 'mappings'} for this ${widget.readiness.templateKind.label.toLowerCase()}.',
                    style: SrType.bodySm(),
                  ),
                  const SizedBox(height: SR.space8),
                  Text(
                    'This affects the printed official permit. Saving sends the requester a fresh e-signature request only when the printable permit changes.',
                    style: SrType.caption(color: context.srColors.muted),
                  ),
                  const SizedBox(height: SR.space16),
                  for (final item in _requirements) ...[
                    Text(item.label, style: SrType.body(w: 600)),
                    const SizedBox(height: SR.space4),
                    if (!item.canConfigure) ...[
                      Text(
                        'This requested item is not linked to an active facility amenity. Update the reservation or add the real amenity in Facility Management.',
                        style: SrType.bodySm(color: context.srColors.redInk),
                      ),
                    ] else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DropdownButtonFormField<String>(
                            initialValue: _selectedCodes[_key(item)],
                            decoration: InputDecoration(
                              labelText: item.isFacility
                                  ? '${item.lane == 'internal' ? 'Internal' : 'External'} facility form row'
                                  : '${item.lane == 'internal' ? 'Internal' : 'External'} amenity form row',
                            ),
                            items: _options(item).entries
                                .map(
                                  (entry) => DropdownMenuItem<String>(
                                    value: entry.key,
                                    child: Text(entry.value),
                                  ),
                                )
                                .toList(),
                            onChanged: _saving
                                ? null
                                : (value) => setState(
                                    () => _selectedCodes[_key(item)] = value,
                                  ),
                          ),
                          if (item.isFacility &&
                              _selectedCodes[_key(item)] == 'other') ...[
                            const SizedBox(height: SR.space4),
                            Text(
                              'The official form will check “Others” and print “${item.label}”.',
                              style: SrType.caption(
                                color: context.srColors.muted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    const SizedBox(height: SR.space16),
                  ],
                  if (_error != null)
                    Text(
                      _error!,
                      style: SrType.bodySm(color: context.srColors.redInk),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(SR.space12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: SR.space8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save mappings'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _save() async {
    if (_requirements.any((item) => !item.canConfigure)) {
      setState(
        () => _error =
            'This reservation includes an item that must be corrected before a permit can be created.',
      );
      return;
    }
    final updates = <PermitMappingUpdate>[];
    for (final item in _requirements) {
      final rowCode = _selectedCodes[_key(item)];
      if (item.sourceId == null || rowCode == null) {
        setState(() => _error = 'Choose an official form row for every item.');
        return;
      }
      updates.add(
        PermitMappingUpdate(
          sourceKind: item.sourceKind,
          sourceId: item.sourceId!,
          rowCode: rowCode,
        ),
      );
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final saved = await widget.state.saveReservationPermitMappings(
      widget.requestId,
      updates,
    );
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error =
            'Mappings were not saved. Refresh the reservation and try again.';
      });
    }
  }
}
