import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../local_pdf_file.dart';

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
  late final Future<LocalPdfFile> _pdfFuture;
  final _controller = PdfViewerController();

  // Created lazily in _onViewerReady, once controller.isReady is true.
  // PdfTextSearcher crashes if constructed before the controller is attached
  // to a viewer (its constructor immediately calls controller!, which is null
  // until the viewer widget initialises).
  PdfTextSearcher? _searcher;

  @override
  void initState() {
    super.initState();
    _pdfFuture = _resolvePdf();
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
      _searcher!.startTextSearch(
        RegExp(query, caseSensitive: false),
        goToFirstMatch: true,
      );
    }
  }

  /// Stable wrapper so pagePaintCallbacks never changes between builds
  /// (a changing PdfViewerParams would reset the viewer).
  void _paintCallback(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    _searcher?.pageTextMatchPaintCallback(canvas, pageRect, page);
  }

  /// Build a regex pattern from 5 consecutive words starting at position 2.
  ///
  /// Why skip 2: chunks often start mid-sentence (e.g. "ken (108).") due to
  /// chunking boundaries — the first couple of tokens are unreliable.
  ///
  /// Why [\s\S]{0,15}? between words instead of \s+: PyMuPDF misencodes some
  /// bullet characters as 'n', while PDFium renders them as '•'. Those glyphs
  /// are not whitespace, so \s+ fails to bridge them. [\s\S]{0,15}? allows up
  /// to 15 arbitrary characters (non-greedy) between words, handling bullets,
  /// tabs, footnote numbers, and any other inter-word noise.
  ///
  /// Why keep words ≥ 2 chars: single-char tokens ('n', '-') are usually
  /// misencoded bullets or stray punctuation from PyMuPDF — excluding them
  /// avoids including noise in the query. But 2-char words like "of", "to",
  /// "is" ARE kept so the regex doesn't silently skip real words that are
  /// present in the PDF text (dropping them with \s+ creates gaps).
  String? _buildQuery() {
    final raw = widget.highlightText;
    if (raw == null || raw.trim().isEmpty) return null;

    // Normalise typographic variants that differ between PDF extractors
    final normalised = raw
        .replaceAll('\u2019', "'") // right single quote → apostrophe
        .replaceAll('\u2018', "'") // left single quote
        .replaceAll('\u201c', '"') // left double quote
        .replaceAll('\u201d', '"') // right double quote
        .replaceAll('\u2013', '-') // en-dash
        .replaceAll('\u2014', '-') // em-dash
        .replaceAll('\ufb01', 'fi') // ﬁ ligature
        .replaceAll('\ufb02', 'fl') // ﬂ ligature
        .replaceAll('\ufb00', 'ff') // ﬀ ligature
        .replaceAll('\ufb03', 'ffi') // ﬃ ligature
        .replaceAll('\ufb04', 'ffl') // ﬄ ligature
        // Symbols that PDFium renders differently: replace with space so they
        // become word boundaries rather than appearing in the query
        .replaceAll('\u2192', ' ') // → arrow
        .replaceAll('\u2190', ' ') // ← arrow
        .replaceAll('\u2022', ' ') // • bullet
        .replaceAll('\u25cf', ' ') // ● bullet variant
        .replaceAll('\u25e6', ' '); // ◦ bullet variant

    // Keep words of 2+ chars (filters single-char bullet noise like 'n')
    final words = normalised
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 2)
        .toList();

    if (words.length < 3) return null;

    // Skip first 2 tokens (chunk-boundary noise), take next 5
    final skip = words.length > 5 ? 2 : 0;
    final phrase = words.skip(skip).take(5).toList();

    // [\s\S]{0,15}? bridges bullets, tabs, and other non-whitespace chars
    // that differ between PyMuPDF and PDFium extraction
    return phrase.map(RegExp.escape).join(r'[\s\S]{0,15}?');
  }

  String _normalizeSourceId(String source) => source
      .replaceAll(RegExp(r'[^A-Za-z0-9\-.]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  Future<LocalPdfFile> _resolvePdf() async {
    final normalizedSource = _normalizeSourceId(widget.source);
    return resolveLocalPdfFile(normalizedSource);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.source.replaceAll('_', ' ');
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: FutureBuilder<LocalPdfFile>(
        future: _pdfFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || snap.data == null) {
            return Center(child: Text('Could not locate ${widget.source}.pdf'));
          }
          final pdf = snap.data!;
          if (pdf.path == null) {
            return Center(
              child: Text(
                pdf.errorMessage ?? 'Could not locate ${widget.source}.pdf',
              ),
            );
          }
          return PdfViewer.file(
            pdf.path!,
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
