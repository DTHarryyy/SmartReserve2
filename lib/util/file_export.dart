import 'package:flutter/foundation.dart';

import 'file_export_web.dart' if (dart.library.io) 'file_export_io.dart';

/// Outcome of a file export. Never throws — callers branch on [ok].
@immutable
class FileExportResult {
  const FileExportResult.success(String this.path, {this.revealSupported = false})
    : error = null;
  const FileExportResult.failure(String this.error)
    : path = null,
      revealSupported = false;

  /// Where the file landed. Null when the export failed, and also null on
  /// platforms that hand the bytes off without exposing a path (web, share
  /// sheets), where [ok] is still true.
  final String? path;
  final String? error;

  /// Whether [revealInFileExplorer] can act on [path]. True only on desktop,
  /// and only when the file was written to a real folder rather than handed
  /// to a share sheet or a browser download.
  final bool revealSupported;

  bool get ok => error == null;
}

/// Writes [contents] out as a `<baseName>-<timestamp>.<extension>` file.
///
/// On desktop this writes straight into the Downloads folder without opening a
/// system file dialog. That is deliberate: `file_saver`'s Windows plugin builds
/// a malformed `OPENFILENAME.lpstrFilter` and runs the shell dialog in-process,
/// which crashes the app natively — below the level any Dart `catch` can reach.
Future<FileExportResult> saveTextFile({
  required String baseName,
  required String extension,
  required String contents,
}) => saveTextFileImpl(
  baseName: baseName,
  extension: extension,
  contents: contents,
);

/// Opens the OS file manager with [path] pre-selected. Only call this when
/// the [FileExportResult] that produced [path] had `revealSupported: true` —
/// it is a best-effort no-op everywhere else.
Future<void> revealInFileExplorer(String path) => revealInFileExplorerImpl(path);

/// `<baseName>-YYYYMMDD-HHmm.<extension>`, shared by both implementations.
String buildExportFileName({
  required String baseName,
  required String extension,
  DateTime? at,
}) {
  final stamp = at ?? DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '$baseName-${stamp.year}${two(stamp.month)}${two(stamp.day)}'
      '-${two(stamp.hour)}${two(stamp.minute)}.$extension';
}
