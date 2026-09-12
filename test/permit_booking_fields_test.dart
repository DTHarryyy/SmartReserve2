import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/facility.dart';
import 'package:smartreserve/model/permit.dart';

void main() {
  test(
    'external permit details preserve explicit Individual and admission choices',
    () {
      const details = ExternalPermitDetails(
        companyOrOrganization: 'Individual',
        completeAddress: 'Aparri, Cagayan',
        contactNumbers: ['09171234567'],
        admissionFeeCentavos: 0,
      );
      expect(details.isIndividual, isTrue);
      expect(details.admissionFeeCentavos, 0);
    },
  );

  test(
    'tables/chairs quantity requirement comes from explicit configuration',
    () {
      const amenity = FacilityAmenity(
        id: 'tables',
        name: 'Seating package',
        priceCentavos: 10000,
        externalPermitRowCode: 'tables_chairs',
        permitQuantityRequired: true,
      );
      expect(amenity.externalPermitRowCode, 'tables_chairs');
      expect(amenity.permitQuantityRequired, isTrue);
    },
  );
}
