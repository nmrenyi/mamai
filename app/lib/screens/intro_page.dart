import 'dart:collection';
import 'dart:io';
import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
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
  Map<String, DownloadInProgress> downloads = HashMap();

  /// Downloads a file from our remote server (easiest way for us to upload
  /// everything)
  downloadFileFromServer(String baseUrl, String filename) async {
    Directory directory = await downloadDir();

    final download = DownloadInProgress(total: 1, current: 0, finished: false);
    downloads[filename] = download;

    // We are using a self-signed cert so to trust only that we create our own
    // dio HTTP client and check that the cert matches our self-signed cert
    String serverCertPem = (await rootBundle.loadString('cert.pem')).replaceAll("\n", "").replaceAll("\r", "").replaceAll(" ", "").trim();

    final dio = Dio();
    (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) {
        return cert.pem.replaceAll("\n", "").replaceAll(" ", "").trim() == serverCertPem;
      };
      return client;
    };

    // TODO basic auth - we can gate the model if required with a password
    // String basicAuthHeader = 'Basic ${base64.encode(utf8.encode(basicAuth))}';

    // Send the request
    await dio
        .download(
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
        });

    download.finished = true;
  }

  // ======= Download related properties ============

  /// Total download progress
  double get progress {
    double total = downloads.values.map((d) => d.total).fold(0, (a, b) => a + b);
    double current = downloads.values.map((d) => d.current).fold(0, (a, b) => a + b);
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
      bool done = files.map((file) => io.File("${_downloadDir!.path}/$file").existsSync()).reduce((a, b) => a && b);

      if (done) {
        // Little bit of a hack over doing a checksum but is is ok for an mvp
        int fileSize = files.map((file) => io.File("${_downloadDir!.path}/$file").lengthSync()).reduce((a, b) => a + b);
        debugPrint('Downloaded files total size: $fileSize bytes');
        if (fileSize == 4564057313) {
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
  static const List<String> files = ["gemma-3n-E4B-it-int4.task", "sentencepiece.model", "Gecko_1024_quant.tflite", "embeddings.sqlite"];

  @override
  Widget build(BuildContext context) {
    Widget nextButton;

    // Our background colour
    Color orange = Color(0xffcc5500);

    if (_downloadDir == null) { // Download dir loading - show loading spinner
      // Start background fetching of the download dir - we can't get it
      // synchronously as the Dart API is a Future
      downloadDir();

      nextButton = Column(
        children: [
          Text("Checking if the LLM is installed..."),
          SizedBox(height: 20),
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(color: orange),
          ),
        ],
      );
    } else if (downloadsDone) { // Download complete - initialise LLM
      if (!llmInitialized) { // LLM not yet initialised - loading spinner
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await SearchPage.waitForLlmInit();

          setState(() {
            llmInitialized = true;
          });
        });

        nextButton = Column(
          children: [
            Text("LLM loading (may take a while the first time)..."),
            SizedBox(height: 20),
            SizedBox(
              width: 64,
              height: 64,
              child: CircularProgressIndicator(color: orange),
            )
          ],
        );
      } else { // LLM initialised - allow user to progress!
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
          child: const Text(
            'Start chat',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }
    } else if (!downloadsStarted) { // Download not yet started - prompt license
      nextButton = ElevatedButton(
        onPressed: () async {
          var accepted = await promptLicense(context);
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
        child: const Text(
          'Download models',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    } else {
      double prog = progress;
      nextButton = Column(children: [
        Text("Downloading models (${(prog * 100).toStringAsFixed(2)}%)"),
        SizedBox(height: 20),
        LinearProgressIndicator(value: progress, color: orange)
      ]);
    }

    // Build initial UI
    return Theme(
      data: ThemeData(
        textTheme: TextTheme.of(context).merge(
            TextTheme(
                bodyMedium: TextStyle(color: Colors.grey[700])
            ),
        )
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
                    padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 24.0),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: 400),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(height: 32),
                            Center(
                              child: Column(
                                children: [
                                  CircleAvatar(
                                    radius: 56,
                                    backgroundColor: Colors.white,
                                    child: Image.asset('images/logo.png'),
                                  ),
                                  const SizedBox(height: 24),
                                  Text(
                                    'Welcome to MAM-Ai',
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.deepOrange,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'An edge-based AI search application designed to support nurses and midwives in Zanzibar in neonatal care. It offers fully offline, on-device functionality and medical guideline-based answers through RAG & finetuning for reliable, private, and context-aware care.',
                                    textAlign: TextAlign.left,
                                  ),
                                ],
                              ),
                            ),
                            // Partners section
                            SizedBox(height: 20),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'In partnership with',
                                  style: TextStyle(fontSize: 16),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 5),
                                Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 20.0,
                                  runSpacing: 5.0,
                                  children: [
                                    // Partner logos
                                    Image.asset('images/epfl.png', height: 20),
                                    Image.asset('images/light.png', height: 25),
                                    Image.asset('images/swiss_tph.png', height: 25),
                                    Image.asset('images/d-tree.jpg', height: 25),
                                    // Add more partners as needed
                                  ],
                                ),
                                const SizedBox(height: 20),
                              ],
                            ),
                            const SizedBox(height: 36),
                            // Next button
                            nextButton,
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              ]
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool?> promptLicense(BuildContext context) {
  bool openedGemmaTos = false;
  bool openedGemmaUsagePolicy = false;

  return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            title: const Text('Accept Gemma3n license'),
            content: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 500),
              child: Column(
                  mainAxisSize: MainAxisSize.min  ,
                  children: [
                    Text(
                        "Please read and accept Gemma3n's license and prohibited usage policy."),
                    SizedBox(height: 30),
                    Text(
                        "Gemma is provided under and subject to the Gemma Terms of Use found at"),
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
                          )
                      ),
                      onTap: () {
                        setState(() {
                          openedGemmaTos = true;
                        });
                        launchUrlString(
                            "https://ai.google.dev/gemma/terms");
                      },
                    ),
                    InkWell(
                      child: Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text(
                            "Gemma3n usage policy",
                            style: TextStyle(
                              color: Colors.blue,
                              decoration: TextDecoration.underline,
                            ),
                          )
                      ),
                      onTap: () {
                        setState(() {
                          openedGemmaUsagePolicy = true;
                        });

                        launchUrlString(
                            "https://ai.google.dev/gemma/prohibited_use_policy");
                      },
                    ),
                  ]
              ),
            ),
            actions: <Widget>[
              TextButton(
                style: TextButton.styleFrom(textStyle: Theme
                    .of(context)
                    .textTheme
                    .labelLarge),
                onPressed: (openedGemmaUsagePolicy && openedGemmaTos)
                    ? () => Navigator.of(context).pop(true)
                    : null,
                child: const Text('Accept'),
              ),
              TextButton(
                style: TextButton.styleFrom(textStyle: Theme
                    .of(context)
                    .textTheme
                    .labelLarge),
                child: const Text('Deny'),
                onPressed: () {
                  openedGemmaTos = false;
                  openedGemmaUsagePolicy = false;
                  Navigator.of(context).pop(false);
                },
              ),
            ],
          );
        });
      });
}

class DownloadInProgress {
    int total;
    int current;
    bool finished;

    DownloadInProgress({required this.total, required this.current, required this.finished});
}
