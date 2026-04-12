import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LocalPdfFile {
  final String? path;
  final String? errorMessage;

  const LocalPdfFile.path(String this.path) : errorMessage = null;

  const LocalPdfFile.error(String this.errorMessage) : path = null;
}

Future<LocalPdfFile> resolveLocalPdfFile(String normalizedSource) async {
  final dir = await getExternalStorageDirectory();
  if (dir == null) {
    return const LocalPdfFile.error('No external storage directory found.');
  }

  final path = '${dir.path}/$normalizedSource.pdf';
  if (!File(path).existsSync()) {
    return LocalPdfFile.error('PDF not found:\n$path');
  }

  return LocalPdfFile.path(path);
}
