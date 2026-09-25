import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'file_export.dart';

Future<FileExportResult> saveTextFileImpl({
  required String baseName,
  required String extension,
  required String contents,
}) => _save(
  baseName: baseName,
  extension: extension,
  bytes: Uint8List.fromList(utf8.encode(contents)),
);

Future<FileExportResult> saveBinaryFileImpl({
  required String baseName,
  required String extension,
  required Uint8List bytes,
}) => _save(baseName: baseName, extension: extension, bytes: bytes);

/// Desktop writes straight into Downloads; mobile stages the file in the cache
/// and hands it to the system share sheet, where the user routes it to Files,
/// Drive, or a printer.
///
/// Mobile cannot reuse the desktop path. `getDownloadsDirectory()` does not
/// fail on Android — it returns the app-private external folder
/// (`Android/data/<pkg>/files/Download`), which no file manager surfaces and
/// which uninstalling wipes. Writing there looks like success but leaves the
/// user with nothing they can open.
Future<FileExportResult> _save({
  required String baseName,
  required String extension,
  required Uint8List bytes,
}) async {
  final fileName = buildExportFileName(
    baseName: baseName,
    extension: extension,
  );
  if (_isDesktop) {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        final file = File(
          '${downloads.path}${Platform.pathSeparator}$fileName',
        );
        await file.writeAsBytes(bytes, flush: true);
        return FileExportResult.success(file.path, revealSupported: true);
      }
    } catch (_) {}
  }
  try {
    final temp = await getTemporaryDirectory();
    final file = File('${temp.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: _mimeType(extension))],
        fileNameOverrides: [fileName],
      ),
    );
    return const FileExportResult.handedOff(shared: true);
  } catch (e) {
    return FileExportResult.failure(e.toString());
  }
}

/// Android resolves the share targets from the MIME type, so a missing or
/// generic type collapses the sheet down to a couple of entries.
String _mimeType(String extension) {
  switch (extension.toLowerCase()) {
    case 'pdf':
      return 'application/pdf';
    case 'csv':
      return 'text/csv';
    case 'json':
      return 'application/json';
    case 'txt':
    case 'md':
      return 'text/plain';
    default:
      return 'application/octet-stream';
  }
}

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

Future<void> revealInFileExplorerImpl(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,$path']);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
  } catch (_) {}
}
