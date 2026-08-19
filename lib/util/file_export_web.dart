import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';

import 'file_export.dart';

/// Web: unaffected by the native Windows filter bug, so it keeps using
/// file_saver's Blob-based download.
Future<FileExportResult> saveTextFileImpl({
  required String baseName,
  required String extension,
  required String contents,
}) async {
  final fileName = buildExportFileName(baseName: baseName, extension: extension);
  try {
    await FileSaver.instance.saveAs(
      name: fileName,
      bytes: Uint8List.fromList(utf8.encode(contents)),
      fileExtension: '',
      includeExtension: false,
      mimeType: extension == 'csv' ? MimeType.csv : MimeType.text,
    );
    return FileExportResult.success(fileName);
  } catch (e) {
    return FileExportResult.failure(e.toString());
  }
}

/// No-op: the browser's own download manager is the closest analogue, and
/// there is no cross-browser API to summon it programmatically.
Future<void> revealInFileExplorerImpl(String path) async {}

