import 'package:latlong2/latlong.dart';

class Campus {
  const Campus({
    required this.name,
    required this.center,
    required this.boundary,
  });

  final String name;
  final LatLng center;
  final List<LatLng> boundary;
}

const campus = Campus(
  name: 'CSU Aparri Campus',
  center: LatLng(18.351462, 121.649120),
  boundary: [
    LatLng(18.353792, 121.646670),
    LatLng(18.354032, 121.650930),
    LatLng(18.351292, 121.652070),
    LatLng(18.349092, 121.651370),
    LatLng(18.348832, 121.647510),
    LatLng(18.351232, 121.646410),
  ],
);

class CampusBuilding {
  const CampusBuilding(this.name, this.coords, {required this.mapped});

  final String name;
  final LatLng coords;

  final bool mapped;
}

const buildings = <CampusBuilding>[
  CampusBuilding(
    'Administration Building',
    LatLng(18.352232, 121.647860),
    mapped: true,
  ),
  CampusBuilding(
    'College of Information and Computing Sciences',
    LatLng(18.351092, 121.649970),
    mapped: true,
  ),
  CampusBuilding(
    'College of Fisheries and Marine Sciences',
    LatLng(18.350292, 121.649070),
    mapped: true,
  ),
  CampusBuilding(
    'Science Laboratory Building',
    LatLng(18.351862, 121.650430),
    mapped: true,
  ),
  CampusBuilding(
    'Library and Learning Resource Center',
    LatLng(18.352522, 121.649460),
    mapped: true,
  ),
  CampusBuilding(
    'Gymnasium and Sports Complex',
    LatLng(18.349732, 121.647670),
    mapped: true,
  ),
  CampusBuilding('Student Center', LatLng(18.351932, 121.648970), mapped: true),
  CampusBuilding(
    'Technology and Livelihood Building',
    LatLng(18.350662, 121.650900),
    mapped: false,
  ),
];

CampusBuilding? buildingNamed(String name) {
  for (final b in buildings) {
    if (b.name == name) return b;
  }
  return null;
}

const categories = <String>[
  'Classroom',
  'Computer Laboratory',
  'Science Laboratory',
  'Auditorium',
  'Conference Room',
  'Function Hall',
  'Gymnasium',
  'Library Space',
  'Outdoor Area',
  'Office',
];

class Amenity {
  const Amenity(this.label, this.group);

  final String label;

  final String group;
}

const amenities = <Amenity>[
  Amenity('Wi-Fi', 'NETWORK'),
  Amenity('Power Outlets', 'UTILITY'),
  Amenity('Air Conditioning', 'COMFORT'),
  Amenity('Projector', 'AV'),
  Amenity('Smart TV', 'AV'),
  Amenity('Sound System', 'AV'),
  Amenity('Whiteboard', 'TEACHING'),
  Amenity('Parking', 'ACCESS'),
  Amenity('PWD Accessibility', 'ACCESS'),
  Amenity('Security Cameras', 'SAFETY'),
  Amenity('Generator', 'UTILITY'),
];

List<String> get standardAmenityLabels => [
  for (final amenity in amenities) amenity.label,
];

const barangays = <String>['Macanaya', 'Maura', 'Punta', 'Centro II', 'Bukig'];

const dayLabels = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const campuses = <String>[
  'CSU Aparri Campus',
  'CSU Andrews Campus',
  'CSU Carig Campus',
];

const floors = <String>[
  'Ground floor',
  '2nd floor',
  '3rd floor',
  '4th floor',
  'Rooftop',
];

const durations = <String>[
  '1 hour',
  '2 hours',
  '4 hours',
  '8 hours',
  'Full day',
];

const advanceLimits = <String>[
  '7 days ahead',
  '14 days ahead',
  '30 days ahead',
  '60 days ahead',
  'One semester',
];

const buffers = <String>['None', '15 minutes', '30 minutes', '1 hour'];

const campusStreets = <String>[
  'Maharlika Highway',
  'CSU Access Road',
  'Macanaya Road',
  'University Avenue',
];

const draftKey = 'smartreserve.addfacility.draft.v1';
