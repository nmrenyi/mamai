import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:io' as io;

import 'package:app/locale_notifier.dart';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app/l10n/app_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'search_page.dart';

class RagBundleLock {
  final String bundleVersion;
  final String bundleUrl;
  final String manifestSha256;
  final String producerCommit;
  final int sourceCount;
  final int chunkCount;

  const RagBundleLock({
    required this.bundleVersion,
    required this.bundleUrl,
    required this.manifestSha256,
    required this.producerCommit,
    required this.sourceCount,
    required this.chunkCount,
  });

  factory RagBundleLock.fromMap(Map<String, dynamic> raw) {
    return RagBundleLock(
      bundleVersion: raw['bundleVersion']?.toString() ?? '',
      bundleUrl: raw['bundleUrl']?.toString() ?? '',
      manifestSha256: raw['manifestSha256']?.toString() ?? '',
      producerCommit: raw['producerCommit']?.toString() ?? '',
      sourceCount: (raw['sourceCount'] as num?)?.toInt() ?? 0,
      chunkCount: (raw['chunkCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The intro page handles licensing & model download.
///
/// The flow is essentially:
/// - Load download directory (short loading spinner from user POV)
/// - [If not downloaded]
///     - Show download button
///     - [User clicks download] Show license dialog
///     - [User clicks accept] Start download
///     - Show progress bar
///     - [Download finishes]
/// - Show start chat button
/// - User moves onto the ChatPage screen
class IntroPage extends StatefulWidget {
  const IntroPage({super.key});

  @override
  State<IntroPage> createState() => _IntroPageState();
}

class _IntroPageState extends State<IntroPage> {
  static const _platform = MethodChannel(
    "io.github.mzsfighters.mam_ai/request_generation",
  );

  // Evaluated once in initState before the first build(). Guards all
  // Android-only code (path_provider, platform channels) so the UI can be
  // developed and tested on web / macOS without a device.
  late final bool _runOnAndroid;
  RagBundleLock? _pinnedBundle;
  String? _bundleInfoError;
  String? _llmInitError;
  bool _llmInitStarted = false;

  @override
  void initState() {
    super.initState();
    _runOnAndroid = !kIsWeb && Platform.isAndroid;
    if (!_runOnAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushReplacementNamed(context, '/chat');
      });
    } else {
      _loadPinnedBundleInfo();
    }
  }

  Map<String, DownloadInProgress> downloads = HashMap();

  // Model files downloaded individually from HuggingFace (public, no auth).
  // Update these URLs if the model repos publish new versions.
  static const Map<String, String> _modelFileUrls = {
    "gemma-4-E4B-it.litertlm":
        "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm",
    "Gecko_1024_quant.tflite":
        "https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/Gecko_1024_quant.tflite",
    "sentencepiece.model":
        "https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/sentencepiece.model",
  };

  // Key used in the downloads map to track bundle download progress.
  static const String _bundleKey = '__rag_bundle__';

  // Marker file written after successful bundle extraction.
  static const String _bundleMarker = '.rag_bundle_ready';

  /// Downloads a single model file from HuggingFace.
  Future<void> downloadFile(String filename) async {
    final directory = await downloadDir();
    final download = DownloadInProgress(total: 1, current: 0, finished: false);
    setState(() => downloads[filename] = download);

    await Dio().download(
      _modelFileUrls[filename]!,
      '${directory.path}/$filename',
      onReceiveProgress: (current, int total) {
        setState(() {
          download.current = current;
          download.total = total;
        });
      },
    );
    setState(() => download.finished = true);
  }

  /// Downloads the RAG bundle tar.gz and extracts embeddings.sqlite + PDFs.
  Future<void> downloadAndExtractBundle() async {
    final bundle = _pinnedBundle;
    if (bundle == null || bundle.bundleUrl.isEmpty) {
      throw StateError('Pinned RAG bundle metadata is unavailable');
    }
    final directory = await downloadDir();
    final tmpPath = '${directory.path}/rag-bundle.tar.gz.tmp';
    final download = DownloadInProgress(total: 1, current: 0, finished: false);
    setState(() => downloads[_bundleKey] = download);

    await Dio().download(
      bundle.bundleUrl,
      tmpPath,
      onReceiveProgress: (current, int total) {
        setState(() {
          download.current = current;
          download.total = total;
        });
      },
    );

    // Decompress and extract in a background isolate to avoid blocking the UI.
    await compute(_extractBundleFiles, {
      'tmpPath': tmpPath,
      'destDir': directory.path,
      'markerPath': '${directory.path}/$_bundleMarker',
      'expectedSourceCount': bundle.sourceCount.toString(),
    });

    final deployRecord = File('${directory.path}/rag_bundle_deployed.json');
    final deployRecordJson = const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'bundle_version': bundle.bundleVersion,
      'deployed_at_utc': DateTime.now().toUtc().toIso8601String(),
      'producer_commit': bundle.producerCommit,
      'manifest_sha256': bundle.manifestSha256,
      'chunk_count': bundle.chunkCount,
      'source_count': bundle.sourceCount,
      'install_source': 'intro_download',
    });
    await deployRecord.writeAsString('$deployRecordJson\n');

    setState(() => download.finished = true);
  }

  Future<void> _loadPinnedBundleInfo() async {
    if (mounted) {
      setState(() => _bundleInfoError = null);
    }
    try {
      final raw = await _platform.invokeMapMethod<String, dynamic>(
        "getPinnedRagBundleInfo",
      );
      if (raw == null) {
        throw StateError('Pinned RAG bundle metadata is missing');
      }
      final bundle = RagBundleLock.fromMap(raw);
      if (!mounted) return;
      setState(() {
        _pinnedBundle = bundle;
        _bundleInfoError = null;
      });
    } on PlatformException catch (e) {
      debugPrint('Failed to load pinned RAG bundle metadata: $e');
      if (!mounted) return;
      setState(() {
        _bundleInfoError = 'Could not load app bundle metadata.';
      });
    } catch (e) {
      debugPrint('Failed to load pinned RAG bundle metadata: $e');
      if (!mounted) return;
      setState(() {
        _bundleInfoError = 'Could not load app bundle metadata.';
      });
    }
  }

  // ======= Download related properties ============

  /// Total download progress
  double get progress {
    double total = downloads.values
        .map((d) => d.total)
        .fold(0, (a, b) => a + b);
    double current = downloads.values
        .map((d) => d.current)
        .fold(0, (a, b) => a + b);
    return current / total;
  }

  /// Download dir, which is null before the future loading it has been resolved
  /// Once resolved, it can be retrieved asynchronously (useful for doing it
  /// inside the build() method to check if the files are done downloading)
  Directory? _downloadDir;

  /// Asynchronously get the download dir
  Future<Directory> downloadDir() async {
    if (_downloadDir == null) {
      final dir = await getExternalStorageDirectory();
      setState(() {
        _downloadDir = dir;
      });
    }

    return _downloadDir!;
  }

  bool get downloadsDone {
    if (downloads.isEmpty && _downloadDir != null && _pinnedBundle != null) {
      final modelsReady = _modelFiles.every((f) {
        final file = io.File('${_downloadDir!.path}/$f');
        return file.existsSync() && file.lengthSync() > 0;
      });
      final bundleReady = io.File(
        '${_downloadDir!.path}/$_bundleMarker',
      ).existsSync();
      final embeddingsFile = io.File('${_downloadDir!.path}/embeddings.sqlite');
      final pdfCount = io.Directory(_downloadDir!.path)
          .listSync()
          .whereType<io.File>()
          .where((f) => f.path.toLowerCase().endsWith('.pdf'))
          .length;
      if (modelsReady && bundleReady) {
        if (!embeddingsFile.existsSync() || embeddingsFile.lengthSync() == 0) {
          return false;
        }
        if (pdfCount != _pinnedBundle!.sourceCount) {
          return false;
        }
        // Sanity-check: Gemma 4 E4B is 3.65 GB — reject truncated downloads.
        final gemmaSize = io.File(
          '${_downloadDir!.path}/gemma-4-E4B-it.litertlm',
        ).lengthSync();
        debugPrint('Gemma model size: $gemmaSize bytes');
        return gemmaSize > 3000000000;
      }
      return false;
    }

    return downloads.isNotEmpty && downloads.values.every((d) => d.finished);
  }

  bool get downloadsStarted => downloads.isNotEmpty;

  /// Whether the LLM has been loaded yet
  bool llmInitialized = false;

  // Model files downloaded individually from HuggingFace.
  static const List<String> _modelFiles = [
    "gemma-4-E4B-it.litertlm",
    "sentencepiece.model",
    "Gecko_1024_quant.tflite",
  ];

  @override
  Widget build(BuildContext context) {
    // Non-Android: show a blank scaffold while initState's post-frame
    // callback redirects to /chat.
    if (!_runOnAndroid) {
      return const Scaffold(body: SizedBox.shrink());
    }

    final l10n = AppLocalizations.of(context);

    Widget nextButton;

    // Our background colour
    const Color orange = Color(0xffDE7356);

    if (_downloadDir == null ||
        (_pinnedBundle == null && _bundleInfoError == null)) {
      // Download dir loading - show loading spinner
      // Start background fetching of the download dir - we can't get it
      // synchronously as the Dart API is a Future
      downloadDir();

      nextButton = Column(
        children: [
          Text(l10n.introCheckingLLM),
          SizedBox(height: 20),
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(color: orange),
          ),
        ],
      );
    } else if (_bundleInfoError != null) {
      nextButton = Column(
        children: [
          Text(_bundleInfoError!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loadPinnedBundleInfo,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(16),
              backgroundColor: orange,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5.0),
              ),
            ),
            child: const Text(
              'Retry',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      );
    } else if (downloadsDone) {
      // Download complete - initialise LLM
      if (_llmInitError != null) {
        nextButton = Column(
          children: [
            Text(
              'Could not initialize the on-device model.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              _llmInitError!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => setState(() => _llmInitError = null),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
                backgroundColor: orange,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5.0),
                ),
              ),
              child: const Text(
                'Retry',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      } else if (!llmInitialized) {
        // LLM not yet initialised - loading spinner
        if (!_llmInitStarted) {
          _llmInitStarted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              await SearchPage.waitForLlmInit();
              if (!mounted) return;
              setState(() {
                llmInitialized = true;
                _llmInitStarted = false;
                _llmInitError = null;
              });
            } catch (e) {
              if (!mounted) return;
              setState(() {
                _llmInitStarted = false;
                _llmInitError = e.toString();
              });
            }
          });
        }

        nextButton = Column(
          children: [
            Text(l10n.introLLMLoading),
            SizedBox(height: 20),
            SizedBox(
              width: 64,
              height: 64,
              child: CircularProgressIndicator(color: orange),
            ),
          ],
        );
      } else {
        // LLM initialised - allow user to progress!
        nextButton = ElevatedButton(
          onPressed: () {
            Navigator.pushReplacementNamed(context, '/chat');
          },
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.all(20),
            backgroundColor: orange,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(5.0),
            ),
            elevation: 2,
          ),
          child: Text(
            l10n.introStartChat,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }
    } else if (!downloadsStarted) {
      // Download not yet started - prompt license
      nextButton = ElevatedButton(
        onPressed: () async {
          var accepted = await promptLicense(context, l10n);
          if (accepted ?? false) {
            for (final filename in _modelFiles) {
              downloadFile(filename);
            }
            downloadAndExtractBundle();
          }
        },
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.all(20),
          backgroundColor: orange,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(5.0),
          ),
          elevation: 2,
        ),
        child: Text(
          l10n.introDownloadModels,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    } else {
      double prog = progress;
      nextButton = Column(
        children: [
          Text(l10n.introDownloadingModels((prog * 100).toStringAsFixed(2))),
          SizedBox(height: 20),
          LinearProgressIndicator(value: progress, color: orange),
        ],
      );
    }

    // Build initial UI
    return Theme(
      data: ThemeData(
        textTheme: TextTheme.of(
          context,
        ).merge(TextTheme(bodyMedium: TextStyle(color: Colors.grey[700]))),
      ),
      child: Scaffold(
        body: SafeArea(
          child: SizedBox(
            height: double.infinity,
            child: CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32.0),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // ── Brand block ──────────────────────────────
                            Column(
                              children: [
                                const SizedBox(height: 72),
                                Center(
                                  child: Image.asset(
                                    'images/logo.png',
                                    width: 96,
                                    height: 96,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Text(
                                  l10n.introWelcome,
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xffDE7356),
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  l10n.introDescription,
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: Colors.grey[500],
                                    height: 1.4,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),

                            // ── Action block ─────────────────────────────
                            Column(
                              children: [
                                // Language toggle
                                Center(
                                  child: ValueListenableBuilder<Locale>(
                                    valueListenable: appLocale,
                                    builder: (_, locale, __) => TextButton(
                                      onPressed: () async {
                                        final newLocale =
                                            locale.languageCode == 'en'
                                            ? const Locale('sw')
                                            : const Locale('en');
                                        appLocale.value = newLocale;
                                        final prefs =
                                            await SharedPreferences.getInstance();
                                        await prefs.setString(
                                          'locale',
                                          newLocale.languageCode,
                                        );
                                      },
                                      child: Text(
                                        locale.languageCode == 'en'
                                            ? AppLocalizations.of(
                                                context,
                                              ).switchToSwahili
                                            : AppLocalizations.of(
                                                context,
                                              ).switchToEnglish,
                                        style: const TextStyle(
                                          color: Color(0xffDE7356),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                // Next button
                                nextButton,
                                const SizedBox(height: 24),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Top-level function so it can run in a separate isolate via compute().
// Decompresses the RAG bundle tar.gz, writes embeddings.sqlite and all
// guideline PDFs to destDir, deletes the temp file, then writes a marker.
Future<void> _extractBundleFiles(Map<String, String> args) async {
  final tmpPath = args['tmpPath']!;
  final destDir = args['destDir']!;
  final markerPath = args['markerPath']!;
  final expectedSourceCount =
      int.tryParse(args['expectedSourceCount'] ?? '') ?? 0;

  final bytes = io.File(tmpPath).readAsBytesSync();
  final archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
  var pdfCount = 0;
  var foundEmbeddings = false;

  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name;

    String? destPath;
    if (name.contains('runtime/') && name.endsWith('embeddings.sqlite')) {
      destPath = '$destDir/embeddings.sqlite';
      foundEmbeddings = true;
    } else if (name.contains('/docs/') && name.endsWith('.pdf')) {
      destPath = '$destDir/${name.split('/').last}';
      pdfCount += 1;
    }

    if (destPath != null) {
      io.File(destPath).writeAsBytesSync(file.content as List<int>);
    }
  }

  io.File(tmpPath).deleteSync();
  if (!foundEmbeddings) {
    throw StateError('RAG bundle did not contain embeddings.sqlite');
  }
  if (expectedSourceCount > 0 && pdfCount != expectedSourceCount) {
    throw StateError(
      'RAG bundle PDF count mismatch: expected $expectedSourceCount, got $pdfCount',
    );
  }
  io.File(markerPath).writeAsStringSync('ok');
}

Future<bool?> promptLicense(BuildContext context, AppLocalizations l10n) {
  bool openedGemmaTos = false;
  bool openedGemmaUsagePolicy = false;

  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(l10n.licenseTitle),
            content: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.licenseIntro),
                  SizedBox(height: 30),
                  Text(l10n.licenseTermsText),
                  SizedBox(height: 15),
                  InkWell(
                    child: Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Text(
                        "ai.google.dev/gemma/terms",
                        style: TextStyle(
                          color: Colors.blue,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                    onTap: () {
                      setState(() {
                        openedGemmaTos = true;
                      });
                      launchUrlString("https://ai.google.dev/gemma/terms");
                    },
                  ),
                  InkWell(
                    child: Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Text(
                        l10n.licenseUsagePolicyLink,
                        style: TextStyle(
                          color: Colors.blue,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                    onTap: () {
                      setState(() {
                        openedGemmaUsagePolicy = true;
                      });

                      launchUrlString(
                        "https://ai.google.dev/gemma/prohibited_use_policy",
                      );
                    },
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                style: TextButton.styleFrom(
                  textStyle: Theme.of(context).textTheme.labelLarge,
                ),
                onPressed: (openedGemmaUsagePolicy && openedGemmaTos)
                    ? () => Navigator.of(context).pop(true)
                    : null,
                child: Text(l10n.licenseAccept),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  textStyle: Theme.of(context).textTheme.labelLarge,
                ),
                child: Text(l10n.licenseDeny),
                onPressed: () {
                  openedGemmaTos = false;
                  openedGemmaUsagePolicy = false;
                  Navigator.of(context).pop(false);
                },
              ),
            ],
          );
        },
      );
    },
  );
}

class DownloadInProgress {
  int total;
  int current;
  bool finished;

  DownloadInProgress({
    required this.total,
    required this.current,
    required this.finished,
  });
}
