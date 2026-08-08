import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../data/campus_data.dart';

double haversine(LatLng a, LatLng b) {
  const r = 6371000.0;
  const t = math.pi / 180;
  final dLat = (b.latitude - a.latitude) * t;
  final dLng = (b.longitude - a.longitude) * t;
  final la1 = a.latitude * t;
  final la2 = b.latitude * t;
  final x =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(la1) * math.cos(la2) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(x.toDouble()));
}

bool inPolygon(LatLng pt, List<LatLng> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final xi = poly[i].longitude, yi = poly[i].latitude;
    final xj = poly[j].longitude, yj = poly[j].latitude;
    if (((yi > pt.latitude) != (yj > pt.latitude)) &&
        (pt.longitude < (xj - xi) * (pt.latitude - yi) / (yj - yi) + xi)) {
      inside = !inside;
    }
  }
  return inside;
}

const _metreInLat = 1 / 111320.0;

LatLng nudge(LatLng from, {double north = 0, double east = 0}) {
  final latPerM = _metreInLat;
  final lngPerM = 1 / (111320.0 * math.cos(from.latitude * math.pi / 180));
  return LatLng(
    from.latitude + north * latPerM,
    from.longitude + east * lngPerM,
  );
}

String compassFrom(LatLng from, LatLng to) {
  final dy = to.latitude - from.latitude;
  final dx =
      (to.longitude - from.longitude) * math.cos(from.latitude * math.pi / 180);
  final deg = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
  const names = [
    'north',
    'north-east',
    'east',
    'south-east',
    'south',
    'south-west',
    'west',
    'north-west',
  ];
  return names[(((deg + 22.5) % 360) ~/ 45)];
}

String formatLat(double v) => v.toStringAsFixed(6);

String formatCoords(LatLng p) =>
    '${formatLat(p.latitude)}, ${formatLat(p.longitude)}';

String formatMetres(double m) =>
    m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

LatLng? parseCoords(String raw) {
  final m = RegExp(
    r'^\s*([+-]?\d{1,3}(?:\.\d+)?)\s*[, ]\s*([+-]?\d{1,3}(?:\.\d+)?)\s*$',
  ).firstMatch(raw);
  if (m == null) return null;
  final lat = double.tryParse(m.group(1)!);
  final lng = double.tryParse(m.group(2)!);
  if (lat == null || lng == null) return null;
  if (lat.abs() > 90 || lng.abs() > 180) return null;
  return LatLng(lat, lng);
}

({CampusBuilding building, double metres})? nearestMappedBuilding(LatLng p) {
  CampusBuilding? best;
  var bestDistance = double.infinity;
  for (final b in buildings) {
    if (!b.mapped) continue;
    final d = haversine(p, b.coords);
    if (d < bestDistance) {
      bestDistance = d;
      best = b;
    }
  }
  return best == null ? null : (building: best, metres: bestDistance);
}

int accuracyForZoom(double zoom) => (2 + (19 - zoom) * 3).round().clamp(2, 40);

const buildingProximityLimit = 90.0;

const accuracyWarnLimit = 15;

class GeoAddress {
  const GeoAddress({
    required this.geoBuilding,
    required this.street,
    required this.barangay,
    required this.municipality,
    required this.province,
    required this.region,
    required this.country,
  });

  final String geoBuilding;
  final String street;
  final String barangay;
  final String municipality;
  final String province;
  final String region;
  final String country;

  Map<String, String> toMap() => {
    'geoBuilding': geoBuilding,
    'street': street,
    'barangay': barangay,
    'municipality': municipality,
    'province': province,
    'region': region,
    'country': country,
  };
}

GeoAddress reverseGeocode(LatLng p) {
  final near = nearestMappedBuilding(p);
  final seed = ((p.latitude * 1e5).round() + (p.longitude * 1e5).round()).abs();
  return GeoAddress(
    geoBuilding: near != null && near.metres <= buildingProximityLimit
        ? near.building.name
        : '',
    street: campusStreets[seed % campusStreets.length],
    barangay: inPolygon(p, campus.boundary)
        ? barangays.first
        : barangays[seed % barangays.length],
    municipality: 'Aparri',
    province: 'Cagayan',
    region: 'Region II (Cagayan Valley)',
    country: 'Philippines',
  );
}
