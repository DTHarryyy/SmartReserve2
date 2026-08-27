library;

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
  final withoutPrefix = raw.replaceFirst(RegExp(r'^.*?message:\s*'), '');
  final trimmed = withoutPrefix
      .replaceFirst(RegExp(r',\s*(code|details|hint):.*$', dotAll: true), '')
      .replaceFirst(RegExp(r'\)\s*$'), '')
      .trim();
  if (trimmed.isEmpty) return fallback;
  return trimmed.endsWith('.') || trimmed.endsWith('!') || trimmed.endsWith('?')
      ? trimmed
      : '$trimmed.';
}
