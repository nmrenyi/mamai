import 'dart:collection';
import 'dart:io';
import 'dart:io' as io;

import 'package:app/locale_notifier.dart';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter/material.dart';
import 'package:app/l10n/app_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'search_page.dart';

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
  // Evaluated once in initState before the first build(). Guards all
  // Android-only code (path_provider, platform channels) so the UI can be
  // developed and tested on web / macOS without a device.
  late final bool _runOnAndroid;

  @override
  void initState() {
    super.initState();
    _runOnAndroid = !kIsWeb && Platform.isAndroid;
    if (!_runOnAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushReplacementNamed(context, '/chat');
      });
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

  // RAG bundle: embeddings.sqlite + 55 guideline PDFs, packaged as a tar.gz
  // from the mamai-medical-guidelines GitHub release.
  // Update this URL when bumping rag-assets.lock.json to a new bundle version.
  static const String _ragBundleUrl =
      "https://github.com/nmrenyi/mamai-medical-guidelines/releases/download/v1.0.0/rag-bundle-v1.0.0.tar.gz";

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
    download.finished = true;
  }

  /// Downloads the RAG bundle tar.gz and extracts embeddings.sqlite + PDFs.
  Future<void> downloadAndExtractBundle() async {
    final directory = await downloadDir();
    final tmpPath = '${directory.path}/rag-bundle.tar.gz.tmp';
    final download = DownloadInProgress(total: 1, current: 0, finished: false);
    setState(() => downloads[_bundleKey] = download);

    await Dio().download(
      _ragBundleUrl,
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
    });

    setState(() => download.finished = true);
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
    if (downloads.isEmpty && _downloadDir != null) {
      final modelsReady = _modelFiles.every(
          (f) => io.File('${_downloadDir!.path}/$f').existsSync());
      final bundleReady = io.File(
          '${_downloadDir!.path}/$_bundleMarker').existsSync();
      if (modelsReady && bundleReady) {
        // Sanity-check: Gemma 4 E4B is 3.65 GB — reject truncated downloads.
        final gemmaSize = io.File(
            '${_downloadDir!.path}/gemma-4-E4B-it.litertlm').lengthSync();
        debugPrint('Gemma model size: $gemmaSize bytes');
        return gemmaSize > 3000000000;
      }
      return false;
    }

    return downloads.isNotEmpty &&
        downloads.values.every((d) => d.finished);
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

    if (_downloadDir == null) {
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
    } else if (downloadsDone) {
      // Download complete - initialise LLM
      if (!llmInitialized) {
        // LLM not yet initialised - loading spinner
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await SearchPage.waitForLlmInit();

          setState(() {
            llmInitialized = true;
          });
        });

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
                                        final prefs = await SharedPreferences
                                            .getInstance();
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

  final bytes = io.File(tmpPath).readAsBytesSync();
  final archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));

  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name;

    String? destPath;
    if (name.contains('runtime/') && name.endsWith('embeddings.sqlite')) {
      destPath = '$destDir/embeddings.sqlite';
    } else if (name.contains('/docs/') && name.endsWith('.pdf')) {
      destPath = '$destDir/${name.split('/').last}';
    }

    if (destPath != null) {
      io.File(destPath).writeAsBytesSync(file.content as List<int>);
    }
  }

  io.File(tmpPath).deleteSync();
  io.File(markerPath).writeAsStringSync('ok');
}

Future<bool?> promptLicense(
  BuildContext context,
  AppLocalizations l10n,
) {
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
