import 'dart:convert';

import '../util/campus_calendar.dart' show formatStamp;
import 'audit_change.dart';

/// Turns the raw `details` / `before_values` / `after_values` payload an
/// audit trigger stored into a short, human-readable list of changes.
///
/// This is what stands between an administrator and a wall of
/// `id: — → 48b71f44-4f53-4d26-9aa3-126fec41562c` — every key here is either
/// dropped as internal bookkeeping, or reformatted into plain language.
/// Nothing is destroyed: callers that need the untrimmed payload still have
/// it via `AuditEntry.rawBefore` / `rawAfter` / `rawDetails`.
List<AuditChange> humanizeAuditPayload({
  required String entityType,
  required String action,
  Map<String, dynamic> details = const {},
  Map<String, dynamic> before = const {},
  Map<String, dynamic> after = const {},
}) {
  final trimmedBefore = _trim(before);
  final trimmedAfter = _trim(after);
  final changes = <AuditChange>[];

  final isCreation = before.isEmpty && trimmedAfter.isNotEmpty;
  if (isCreation &&
      (entityType == 'account' || entityType == 'facility')) {
    final whitelist = entityType == 'account'
        ? _accountCreationKeys
        : _facilityCreationKeys;
    for (final key in whitelist) {
      if (!trimmedAfter.containsKey(key)) continue;
      final formatted = _formatValue(key, trimmedAfter[key]);
      if (formatted == null) continue;
      changes.add(AuditChange(label: _labelFor(key), after: formatted));
    }
  } else {
    final keys = {...trimmedBefore.keys, ...trimmedAfter.keys};
    if (keys.contains('latitude') || keys.contains('longitude')) {
      final beforeLat = trimmedBefore['latitude'];
      final beforeLng = trimmedBefore['longitude'];
      final afterLat = trimmedAfter['latitude'];
      final afterLng = trimmedAfter['longitude'];
      if (!_sameValue(beforeLat, afterLat) ||
          !_sameValue(beforeLng, afterLng)) {
        final location = AuditChange(
          label: 'Location',
          before: _formatLatLng(beforeLat, beforeLng),
          after: _formatLatLng(afterLat, afterLng),
        );
        if (location.before != null || location.after != null) {
          changes.add(location);
        }
      }
      keys
        ..remove('latitude')
        ..remove('longitude');
    }
    for (final key in keys) {
      final beforeValue = trimmedBefore[key];
      final afterValue = trimmedAfter[key];
      if (_sameValue(beforeValue, afterValue)) continue;
      final formattedBefore = _formatValue(key, beforeValue);
      final formattedAfter = _formatValue(key, afterValue);
      if (formattedBefore == null && formattedAfter == null) continue;
      changes.add(
        AuditChange(
          label: _labelFor(key),
          before: formattedBefore ?? '—',
          after: formattedAfter ?? '—',
        ),
      );
    }
  }

  details.forEach((key, value) {
    if (value == null) return;
    final formatted = _formatDetailValue(key, value);
    if (formatted == '—') return;
    changes.add(AuditChange(label: _labelFor(key), after: formatted));
  });

  if (changes.isEmpty) {
    final sentence = action.trim().isEmpty
        ? 'This action'
        : _sentenceCase(action.trim());
    changes.add(AuditChange.note('$sentence — no field changes recorded'));
  }
  return changes;
}

// Columns and payload keys that are internal bookkeeping, not a fact an
// administrator reading the log cares about.
const _noiseKeys = {
  'id',
  'created_at',
  'updated_at',
  'updated_by',
  'updated_by_name',
  'actor_id',
  'target_id',
  'source_id',
  'source_type',
  'entity_id',
  'avatar_url',
  'search_vector',
  'geo_edited',
};

const _labelOverrides = {
  'account_status': 'Status',
  'verification_status': 'Verification',
  'full_name': 'Name',
  'invitation_sent_at': 'Invitation sent',
  'public_listing': 'Public listing',
  'pin_confidence': 'Pin confidence',
  'confirmed_outside': 'Confirmed outside boundary',
  'requires_approval': 'Requires approval',
  'photo_paths': 'Photos',
  'row_count': 'Rows exported',
};

// Creation events summarise instead of diffing every column against an
// empty before-state. `invitation_sent_at` is included for accounts because
// "when was this sent" is the one fact an admin looks for on an invite.
const _accountCreationKeys = [
  'role',
  'account_status',
  'full_name',
  'invitation_sent_at',
];
const _facilityCreationKeys = ['name', 'building', 'capacity', 'status'];

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _isoDatePattern = RegExp(r'^\d{4}-\d{2}-\d{2}');
final _snakeLikePattern = RegExp(r'^[a-z]+(_[a-z0-9]+)*$');

Map<String, dynamic> _trim(Map<String, dynamic> source) => {
  for (final entry in source.entries)
    if (!_noiseKeys.contains(entry.key)) entry.key: entry.value,
};

bool _sameValue(Object? a, Object? b) {
  String norm(Object? v) => (v == null || v == '') ? '' : jsonEncode(v);
  return norm(a) == norm(b);
}

String? _formatLatLng(Object? lat, Object? lng) {
  if (lat == null && lng == null) return null;
  String fmt(Object? v) => v is num ? v.toStringAsFixed(6) : '—';
  return '${fmt(lat)}, ${fmt(lng)}';
}

String? _formatValue(String key, Object? value) {
  if (value == null) return null;
  if (value is bool) return value ? 'Yes' : 'No';
  if (value is num) return _formatNumber(value);
  if (value is List) return _formatList(key, value);
  if (value is Map) return _formatDetailValue(key, value);
  final text = value.toString();
  if (text.isEmpty) return null;
  if (_uuidPattern.hasMatch(text)) return null;
  if (_isoDatePattern.hasMatch(text)) {
    final parsed = DateTime.tryParse(text);
    if (parsed != null) return formatStamp(parsed.toLocal());
  }
  if (_snakeLikePattern.hasMatch(text)) return _sentenceCase(text);
  return text;
}

String _formatNumber(num value) =>
    value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();

String _formatList(String key, List<Object?> value) {
  if (value.isEmpty) return 'None';
  final lower = key.toLowerCase();
  if (lower.contains('photo')) {
    return '${value.length} photo${value.length == 1 ? '' : 's'}';
  }
  if (lower.contains('amenit')) {
    return '${value.length} amenit${value.length == 1 ? 'y' : 'ies'}';
  }
  if (value.length <= 3) return value.map((e) => '$e').join(', ');
  return '${value.length} items';
}

String _formatDetailValue(String key, Object? value) {
  if (value is Map) {
    final parts = <String>[];
    value.forEach((k, v) {
      if (v == null || v == '') return;
      final formatted = _formatValue('$k', v);
      if (formatted == null) return;
      parts.add('${_labelFor('$k')}: $formatted');
    });
    return parts.isEmpty ? '—' : parts.join(', ');
  }
  return _formatValue(key, value) ?? '—';
}

String _labelFor(String key) => _labelOverrides[key] ?? _sentenceCase(key);

String _sentenceCase(String value) {
  final spaced = value.replaceAll('_', ' ').trim();
  if (spaced.isEmpty) return spaced;
  return spaced[0].toUpperCase() + spaced.substring(1);
}
