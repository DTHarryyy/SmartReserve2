library;

const reservationServiceUpdatingMessage =
    'Reservation requests are temporarily unavailable while SmartReserve '
    'is being updated. Please try again shortly.';

/// Returns a stable requester-facing message for reservation failures.
///
/// A missing required reservation RPC is a deployment problem, not something
/// the requester can correct. Keep the database function name and PostgREST
/// schema details out of the UI while still leaving other validation messages
/// available through [friendlyBackendMessage].
String reservationBackendMessage(Object error) {
  final raw = '$error';
  final normalized = raw.toLowerCase();
  final missingSubmissionContract =
      normalized.contains('submit_reservation_v3') &&
      (normalized.contains('pgrst202') ||
          normalized.contains('could not find the function') ||
          normalized.contains('function not found'));
  if (missingSubmissionContract) return reservationServiceUpdatingMessage;
  if (raw.contains('23P01') || normalized.contains('booked')) {
    return 'That time was just booked. Refresh and choose another slot.';
  }
  if (raw.contains('40001') || normalized.contains('changed')) {
    return 'This reservation changed in another session. It has been refreshed.';
  }
  if (raw.contains('23514')) {
    return 'One of those values is out of range. Check the attendee count '
        'and times, then try again.';
  }
  final storageUploadDenied =
      normalized.contains('row-level security') ||
      (normalized.contains('storage') && normalized.contains('unauthorized'));
  if (storageUploadDenied) {
    return 'Your signature upload was not authorized. Refresh the '
        'reservation and try again.';
  }
  // Browser transport errors do not always include the same punctuation or
  // status text across Flutter web releases. Never expose that SDK exception
  // to a requester or administrator.
  final signatureFunctionUnavailable =
      normalized.contains('functionsfetchexception') ||
      (normalized.contains('function') &&
          normalized.contains('fetch') &&
          normalized.contains('status: 0'));
  if (signatureFunctionUnavailable) {
    return 'The permit service could not be reached. Refresh and try again.';
  }
  return friendlyBackendMessage(raw);
}

/// Turns a thrown backend error into something worth showing a person.
///
/// `PostgrestException.toString()` reads
/// `PostgrestException(message: …, code: …, details: …, hint: …)`. Only the
/// message half means anything to a requester, so the machine fields are
/// stripped rather than pasted into the UI.
String friendlyBackendMessage(
  String raw, {
  String fallback =
      'That request could not be sent. Check the details and '
      'try again.',
}) {
  final withoutPrefix = raw
      .replaceFirst(RegExp(r'^.*?message:\s*'), '')
      .replaceFirst(
        RegExp(
          r'^(?:bad state|stateerror|exception)\s*:\s*',
          caseSensitive: false,
        ),
        '',
      );
  final trimmed = withoutPrefix
      .replaceFirst(RegExp(r',\s*(code|details|hint):.*$', dotAll: true), '')
      .replaceFirst(RegExp(r'\)\s*$'), '')
      .trim();
  if (trimmed.isEmpty) return fallback;
  return trimmed.endsWith('.') || trimmed.endsWith('!') || trimmed.endsWith('?')
      ? trimmed
      : '$trimmed.';
}
