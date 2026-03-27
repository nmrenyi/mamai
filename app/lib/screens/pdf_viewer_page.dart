import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// Full-screen in-app PDF viewer that opens a local PDF at a specific page
/// and highlights the retrieved text chunk.
///
/// [source] is the filename stem (e.g. "WHO_PositiveBirth_2018").
/// [page] is 1-indexed.
/// [highlightText] is the raw chunk text to search and highlight on the page.
class PdfViewerPage extends StatefulWidget {
  final String source;
  final int page;
  final String? highlightText;

  const PdfViewerPage({
    super.key,
    required this.source,
    required this.page,
    this.highlightText,
  });

  @override
  State<PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  late final Future<String> _pathFuture;
  final _controller = PdfViewerController();

  // Created lazily in _onViewerReady, once controller.isReady is true.
  // PdfTextSearcher crashes if constructed before the controller is attached
  // to a viewer (its constructor immediately calls controller!, which is null
  // until the viewer widget initialises).
  PdfTextSearcher? _searcher;

  @override
  void initState() {
    super.initState();
    _pathFuture = _resolvePath();
  }

  @override
  void dispose() {
    _searcher?.dispose();
    super.dispose();
  }

  void _onViewerReady(PdfDocument _, PdfViewerController __) {
    if (_searcher != null) return;
    _searcher = PdfTextSearcher(_controller);
    final query = _buildQuery();
    if (query != null) {
      _searcher!.startTextSearch(query, caseInsensitive: true, goToFirstMatch: true);
    }
  }

  /// Stable wrapper so pagePaintCallbacks never changes between builds
  /// (a changing PdfViewerParams would reset the viewer).
  void _paintCallback(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    _searcher?.pageTextMatchPaintCallback(canvas, pageRect, page);
  }

  /// Collapse whitespace and return the first ~80-char word-boundary substring
  /// of the chunk — long enough to be unique, short enough to survive minor
  /// whitespace differences between PyMuPDF and PDFium text extraction.
  String? _buildQuery() {
    final raw = widget.highlightText;
    if (raw == null || raw.trim().isEmpty) return null;
    final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= 80) return collapsed;
    final cut = collapsed.lastIndexOf(' ', 80);
    return cut > 40 ? collapsed.substring(0, cut) : collapsed.substring(0, 80);
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
            controller: _controller,
            initialPageNumber: widget.page,
            params: PdfViewerParams(
              onViewerReady: _onViewerReady,
              pagePaintCallbacks: [_paintCallback],
            ),
          );
        },
      ),
    );
  }
}
