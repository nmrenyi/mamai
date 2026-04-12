class LocalPdfFile {
  final String? path;
  final String? errorMessage;

  const LocalPdfFile.path(String this.path) : errorMessage = null;

  const LocalPdfFile.error(String this.errorMessage) : path = null;
}

Future<LocalPdfFile> resolveLocalPdfFile(String normalizedSource) async {
  return const LocalPdfFile.error(
    'PDF viewing is only available on Android devices.',
  );
}
