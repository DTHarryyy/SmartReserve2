import 'reports_data.dart';
import 'report_scope_url_stub.dart'
    if (dart.library.html) 'report_scope_url_web.dart'
    as impl;

class ReportLinkSelection {
  const ReportLinkSelection({
    required this.range,
    this.category,
    this.facilityId,
  });

  final ReportRange range;
  final String? category;
  final String? facilityId;
}

ReportLinkSelection? readInitialReportLink() {
  final uri = impl.currentUri();
  if (uri.queryParameters['section'] != 'reports') return null;
  return _selectionFromUri(uri);
}

String currentReportLink(ReportLinkSelection selection) =>
    impl.canonicalReportUrl(_uriForSelection(selection));

void replaceReportLink(ReportLinkSelection selection) =>
    impl.replaceReportUrl(_uriForSelection(selection));

bool get canCopyReportLink => impl.canUseReportLinks;

ReportLinkSelection _selectionFromUri(Uri uri) {
  final range = switch (uri.queryParameters['report_range']) {
    'week' => ReportRange.week,
    'semester' => ReportRange.semester,
    'last12Months' => ReportRange.last12Months,
    _ => ReportRange.month,
  };
  final category = _clean(uri.queryParameters['report_category']);
  final facility = _looksLikeUuid(uri.queryParameters['report_facility'])
      ? uri.queryParameters['report_facility']
      : null;
  return ReportLinkSelection(
    range: range,
    category: category,
    facilityId: facility,
  );
}

Uri _uriForSelection(ReportLinkSelection selection) {
  final current = impl.currentUri();
  final next = Map<String, String>.from(current.queryParameters)
    ..['section'] = 'reports'
    ..['report_range'] = selection.range.name;
  if (selection.category == null || selection.category!.trim().isEmpty) {
    next.remove('report_category');
  } else {
    next['report_category'] = selection.category!.trim();
  }
  if (_looksLikeUuid(selection.facilityId)) {
    next['report_facility'] = selection.facilityId!;
  } else {
    next.remove('report_facility');
  }
  return current.replace(queryParameters: next);
}

String? _clean(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed.length > 80) return null;
  return trimmed;
}

bool _looksLikeUuid(String? value) =>
    value != null &&
    RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);
