import '../data/campus_data.dart';
import 'facility.dart';

String _amenityKey(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

List<String> includedFacilityAmenities(Facility facility) {
  final seen = <String>{};
  final labels = <String>[];
  for (final raw in facility.amenities) {
    final label = raw.trim();
    if (label.isEmpty) continue;
    final key = _amenityKey(label);
    if (seen.add(key)) labels.add(label);
  }
  return labels;
}

List<String> requestableAmenityLabels(Facility facility) {
  final included = {
    for (final label in includedFacilityAmenities(facility)) _amenityKey(label),
  };
  return [
    for (final label in standardAmenityLabels)
      if (!included.contains(_amenityKey(label))) label,
  ];
}

List<String> normalizeRequestedAmenityLabels(
  Facility facility,
  Iterable<String> values,
) {
  final requested = {
    for (final value in values) _amenityKey(value),
  };
  final included = {
    for (final label in includedFacilityAmenities(facility)) _amenityKey(label),
  };
  return [
    for (final label in standardAmenityLabels)
      if (requested.contains(_amenityKey(label)) &&
          !included.contains(_amenityKey(label)))
        label,
  ];
}
