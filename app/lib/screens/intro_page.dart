import 'dart:collection';
import 'dart:io';
import 'dart:io' as io;

import 'package:app/locale_notifier.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// Downloads a file from our remote server (easiest way for us to upload
  /// everything)
  downloadFileFromServer(String baseUrl, String filename) async {
    Directory directory = await downloadDir();

    final download = DownloadInProgress(total: 1, current: 0, finished: false);
    downloads[filename] = download;

    // We are using a self-signed cert so to trust only that we create our own
    // dio HTTP client and check that the cert matches our self-signed cert
    String serverCertPem = (await rootBundle.loadString(
      'cert.pem',
    )).replaceAll("\n", "").replaceAll("\r", "").replaceAll(" ", "").trim();

    final dio = Dio();
    (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) {
        return cert.pem.replaceAll("\n", "").replaceAll(" ", "").trim() ==
            serverCertPem;
      };
      return client;
    };

    // TODO basic auth - we can gate the model if required with a password
    // String basicAuthHeader = 'Basic ${base64.encode(utf8.encode(basicAuth))}'

    // Send the request
    await dio.download(
      baseUrl + filename,
      '${directory.path}/$filename',
      options: Options(
        // headers: {"authorization": basicAuthHeader}, // TODO basic auth
      ),
      onReceiveProgress: (current, int total) {
        setState(() {
          download.current = current;
          download.total = total;
        });
      },
    );

    download.finished = true;
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
      bool done = files
          .map((file) => io.File("${_downloadDir!.path}/$file").existsSync())
          .reduce((a, b) => a && b);

      if (done) {
        // Little bit of a hack over doing a checksum but is is ok for an mvp
        int fileSize = files
            .map((file) => io.File("${_downloadDir!.path}/$file").lengthSync())
            .reduce((a, b) => a + b);
        debugPrint('Downloaded files total size: $fileSize bytes');
        // Accept any total > 4 GB — ensures Gemma (4.1 GB) is present
        // regardless of embeddings.sqlite size (which varies with content).
        if (fileSize > 4000000000) {
          return true;
        }
      }
    }

    return downloads.isNotEmpty &&
        downloads.values.map((d) => d.finished).fold(true, (a, b) => a && b);
  }

  bool get downloadsStarted => downloads.isNotEmpty;

  /// Whether the LLM has been loaded yet
  bool llmInitialized = false;

  /// List of remote model files to download
  static const List<String> files = [
    "gemma-3n-E4B-it-int4.task",
    "sentencepiece.model",
    "Gecko_1024_quant.tflite",
    "embeddings.sqlite",
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
            for (var filename in files) {
              downloadFileFromServer("https://152.67.91.164/", filename);
            }
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
