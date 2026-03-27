import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// Full-screen in-app PDF viewer that opens a local PDF at a specific page.
///
/// [source] is the filename stem (e.g. "WHO_PositiveBirth_2018").
/// The PDF is expected at getExternalStorageDirectory()/<source>.pdf,
/// which is the same directory the Android side stores downloaded model files.
/// [page] is 1-indexed.
class PdfViewerPage extends StatefulWidget {
  final String source;
  final int page;

  const PdfViewerPage({super.key, required this.source, required this.page});

  @override
  State<PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  late final Future<String> _pathFuture;

  @override
  void initState() {
    super.initState();
    _pathFuture = _resolvePath();
  }

  Future<String> _resolvePath() async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) throw StateError('No external storage directory');
    return '${dir.path}/${widget.source}.pdf';
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.source.replaceAll('_', ' ');
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: FutureBuilder<String>(
        future: _pathFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || snap.data == null) {
            return Center(child: Text('Could not locate ${widget.source}.pdf'));
          }
          final path = snap.data!;
          if (!File(path).existsSync()) {
            return Center(child: Text('PDF not found:\n$path'));
          }
          return PdfViewer.file(
            path,
            initialPageNumber: widget.page,
          );
        },
      ),
    );
  }
}
