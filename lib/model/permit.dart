import '../theme/sr_tokens.dart';

enum PermitStatus {
  active('active', 'Active'),
  superseded('superseded', 'Superseded'),
  void_('void', 'Void');

  const PermitStatus(this.raw, this.label);
  final String raw;
  final String label;
  SrTone get tone => switch (this) {
    PermitStatus.active => SrTone.success,
    PermitStatus.superseded => SrTone.neutral,
    PermitStatus.void_ => SrTone.error,
  };
  static PermitStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => PermitStatus.superseded,
  );
}

enum PermitTemplateKind {
  internal('internal', 'Internal official template'),
  external('external', 'External official template');

  const PermitTemplateKind(this.raw, this.label);
  final String raw;
  final String label;
  static PermitTemplateKind fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => PermitTemplateKind.external,
  );
}

enum PermitGenerationStatus {
  pending('pending'),
  generating('generating'),
  ready('ready'),
  blockedData('blocked_data'),
  failed('failed');

  const PermitGenerationStatus(this.raw);
  final String raw;
  static PermitGenerationStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => PermitGenerationStatus.pending,
  );
}

enum OfficialSignatureSlot {
  internalApprover('internal_approver', 'Internal approving official'),
  externalRecommender('external_recommender', 'Business Coordinator'),
  externalAuthorizedOfficial(
    'external_authorized_official',
    'President/Authorized Official',
  );

  const OfficialSignatureSlot(this.raw, this.label);
  final String raw;
  final String label;
}

enum PermitItemRowCode {
  internalAudioVisualMainHall('facility:audio_visual_main_hall'),
  internalConferenceRoom('facility:conference_room'),
  internalFacilityOther('facility:other'),
  internalSoundSystem('equipment:sound_system'),
  internalOverheadProjector('equipment:overhead_projector'),
  internalLcdAccessories('equipment:lcd_accessories'),
  internalEquipmentOther('equipment:other'),
  externalGymAuditorium('external:gym_auditorium'),
  externalTablesChairs('external:tables_chairs'),
  externalLcdProjector('external:lcd_projector'),
  externalAvr('external:avr'),
  externalLedVideoWall('external:led_video_wall'),
  externalAccommodation('external:accommodation'),
  externalLoveHall('external:love_hall'),
  externalOther('external:other');

  const PermitItemRowCode(this.raw);
  final String raw;
}

class ExternalPermitDetails {
  const ExternalPermitDetails({
    required this.companyOrOrganization,
    required this.completeAddress,
    required this.contactNumbers,
    required this.admissionFeeCentavos,
  });
  final String companyOrOrganization;
  final String completeAddress;
  final List<String> contactNumbers;
  final int admissionFeeCentavos;
  bool get isIndividual => companyOrOrganization == 'Individual';
}

/// A real, reservation-specific mapping that is still missing from the
/// printable official form. These values come from the readiness RPC; they
/// are never inferred from labels in the client.
class PermitMappingRequirement {
  const PermitMappingRequirement({
    required this.sourceKind,
    required this.label,
    required this.lane,
    this.sourceId,
    this.canConfigure = false,
  });

  final String sourceKind;
  final String? sourceId;
  final String label;
  final String lane;
  final bool canConfigure;

  factory PermitMappingRequirement.fromJson(Map<String, dynamic> json) =>
      PermitMappingRequirement(
        sourceKind: '${json['source_kind'] ?? ''}',
        sourceId: json['source_id'] as String?,
        label: '${json['label'] ?? 'Permit item'}',
        lane: '${json['lane'] ?? 'external'}',
        canConfigure: json['can_configure'] == true,
      );

  bool get isFacility => sourceKind == 'facility';
}

class PermitMappingUpdate {
  const PermitMappingUpdate({
    required this.sourceKind,
    required this.sourceId,
    required this.rowCode,
  });

  final String sourceKind;
  final String sourceId;
  final String rowCode;

  Map<String, dynamic> toJson() => {
    'source_kind': sourceKind,
    'source_id': sourceId,
    'row_code': rowCode,
  };
}

class PermitReadiness {
  const PermitReadiness({
    required this.ready,
    required this.templateKind,
    required this.blockerCodes,
    this.configurationReady = true,
    this.missingMappings = const [],
  });
  final bool ready;
  final PermitTemplateKind templateKind;
  final List<String> blockerCodes;
  final bool configurationReady;
  final List<PermitMappingRequirement> missingMappings;
  factory PermitReadiness.fromJson(Map<String, dynamic> json) =>
      PermitReadiness(
        ready: json['ready'] == true,
        templateKind: PermitTemplateKind.fromRaw(
          '${json['template_kind'] ?? 'external'}',
        ),
        blockerCodes: [
          for (final code in json['blockers'] as List? ?? const []) '$code',
        ],
        configurationReady: json['configuration'] is Map
            ? (json['configuration'] as Map)['ready'] == true
            : !(json['blockers'] as List? ?? const []).contains(
                'unmapped_permit_item',
              ),
        missingMappings: [
          for (final item
              in ((json['configuration'] is Map
                          ? (json['configuration'] as Map)['missing_mappings']
                          : json['missing_mappings'])
                      as List? ??
                  const []))
            if (item is Map)
              PermitMappingRequirement.fromJson(
                Map<String, dynamic>.from(item),
              ),
        ],
      );
  String messageFor(String code) => switch (code) {
    'not_confirmed' => 'Reservation approval is required.',
    'full_payment_required' => 'Full payment must be verified.',
    'requester_unit_required' => 'Office/College is required.',
    'external_details_required' => 'External permit details are incomplete.',
    'permit_items_required' => 'Permit item snapshots are missing.',
    'unmapped_permit_item' =>
      'Permit setup is incomplete for this reservation.',
    'schedule_required' => 'An active reservation schedule is required.',
    'external_row_limit' =>
      'The selected items exceed the official eight-row table.',
    'duplicate_external_row' =>
      'Multiple items map ambiguously to one official row.',
    'item_quantity_required' => 'Tables/chairs quantity is required.',
    'requester_signature_required' => 'Requester signature is required.',
    'internal_approver_signature_required' =>
      'Internal approving signature is required.',
    'external_recommender_signature_required' =>
      'Business Coordinator signature is required.',
    'external_authorized_signature_required' =>
      'President/Authorized Official signature is required.',
    _ => 'Official permit processing is incomplete.',
  };
}

class ReservationPermit {
  const ReservationPermit({
    required this.id,
    required this.requestId,
    required this.permitNumber,
    required this.version,
    required this.status,
    required this.issuedAt,
    required this.templateKind,
    required this.templateSha256,
    required this.generationStatus,
    this.generationErrorCode,
    this.storagePath,
    this.pdfSha256,
    this.pdfByteSize,
    this.pdfGeneratedAt,
    this.voidedAt,
    this.voidReason,
    this.userSignatureId,
    this.internalApproverSignatureId,
    this.externalRecommenderSignatureId,
    this.externalAuthorizedSignatureId,
    this.deliveryStatus = 'not_sent',
    this.deliveredAt,
  });
  final String id;
  final String requestId;
  final String permitNumber;
  final int version;
  final PermitStatus status;
  final DateTime issuedAt;
  final PermitTemplateKind templateKind;
  final String templateSha256;
  final PermitGenerationStatus generationStatus;
  final String? generationErrorCode;
  final String? storagePath;
  final String? pdfSha256;
  final int? pdfByteSize;
  final DateTime? pdfGeneratedAt;
  final DateTime? voidedAt;
  final String? voidReason;
  final String? userSignatureId;
  final String? internalApproverSignatureId;
  final String? externalRecommenderSignatureId;
  final String? externalAuthorizedSignatureId;
  final String deliveryStatus;
  final DateTime? deliveredAt;
  bool get isGenerated =>
      status == PermitStatus.active &&
      generationStatus == PermitGenerationStatus.ready &&
      storagePath?.isNotEmpty == true;
  bool get isDelivered => deliveryStatus == 'sent' && deliveredAt != null;
  bool get isDownloadable => isGenerated && isDelivered;
  factory ReservationPermit.fromJson(Map<String, dynamic> json) =>
      ReservationPermit(
        id: '${json['id']}',
        requestId: '${json['request_id']}',
        permitNumber: '${json['permit_number'] ?? ''}',
        version: (json['version'] as num?)?.toInt() ?? 1,
        status: PermitStatus.fromRaw('${json['status'] ?? 'superseded'}'),
        issuedAt: DateTime.parse('${json['issued_at']}'),
        templateKind: PermitTemplateKind.fromRaw(
          '${json['template_kind'] ?? 'external'}',
        ),
        templateSha256: '${json['template_sha256'] ?? ''}',
        generationStatus: PermitGenerationStatus.fromRaw(
          '${json['generation_status'] ?? 'pending'}',
        ),
        generationErrorCode: json['generation_error_code'] as String?,
        storagePath: json['storage_path'] as String?,
        pdfSha256: json['pdf_sha256'] as String?,
        pdfByteSize: (json['pdf_byte_size'] as num?)?.toInt(),
        pdfGeneratedAt: json['pdf_generated_at'] == null
            ? null
            : DateTime.parse('${json['pdf_generated_at']}'),
        voidedAt: json['voided_at'] == null
            ? null
            : DateTime.parse('${json['voided_at']}'),
        voidReason: json['void_reason'] as String?,
        userSignatureId: json['user_signature_id'] as String?,
        internalApproverSignatureId:
            json['internal_approver_signature_id'] as String?,
        externalRecommenderSignatureId:
            json['external_recommender_signature_id'] as String?,
        externalAuthorizedSignatureId:
            json['external_authorized_signature_id'] as String?,
        deliveryStatus: '${json['delivery_status'] ?? 'not_sent'}',
        deliveredAt: json['delivered_at'] == null
            ? null
            : DateTime.parse('${json['delivered_at']}'),
      );
}
