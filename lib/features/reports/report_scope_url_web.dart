// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

Uri currentUri() => Uri.base;

String canonicalReportUrl(Uri uri) => uri.toString();

void replaceReportUrl(Uri uri) {
  html.window.history.replaceState(null, '', uri.toString());
}

const bool canUseReportLinks = true;
