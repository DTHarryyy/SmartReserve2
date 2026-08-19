import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'file_export.dart';

Future<FileExportResult> saveTextFileImpl({
  required String baseName,
  required String extension,
  required String contents,
}) async {
  final fileName = buildExportFileName(
    baseName: baseName,
    extension: extension,
  );
  final bytes = utf8.encode(contents);
  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      final file = File('${downloads.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(bytes, flush: true);
      return FileExportResult.success(file.path, revealSupported: _isDesktop);
    }
  } catch (_) {}
  try {
    final temp = await getTemporaryDirectory();
    final file = File('${temp.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], fileNameOverrides: [fileName]),
    );
    return FileExportResult.success(file.path);
  } catch (e) {
    return FileExportResult.failure(e.toString());
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
