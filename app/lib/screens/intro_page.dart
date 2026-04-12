import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:io' as io;
import 'dart:isolate';
import 'package:app/locale_notifier.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app/l10n/app_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'search_page.dart';

const _bundleStageDecompressing = 'decompressing';
const _bundleStageScanning = 'scanning';
const _bundleStageExtracting = 'extracting';
const _bundleStageVerifying = 'verifying';

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
///     - Show per-file progress
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
          download.updateProgress(current, total);
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
          download.updateProgress(current, total);
        });
      },
    );
    setState(() {
      download.setFinalizingProgress(
        _bundleStageDecompressing,
        nextCurrent: 0,
        nextTotal: download.total > 0 ? download.total : 1,
      );
    });

    await _extractBundleFilesWithProgress(
      tmpPath: tmpPath,
      destDir: directory.path,
      markerPath: '${directory.path}/$_bundleMarker',
      expectedSourceCount: bundle.sourceCount,
      download: download,
    );

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

    setState(() {
      download.finished = true;
      download.finalizing = false;
      download.stage = null;
      download.displayedEta = null;
      download.displayedSpeedBytesPerSecond = 0;
    });
  }

  Future<void> _extractBundleFilesWithProgress({
    required String tmpPath,
    required String destDir,
    required String markerPath,
    required int expectedSourceCount,
    required DownloadInProgress download,
  }) async {
    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    final completion = Completer<void>();
    StreamSubscription? progressSubscription;
    StreamSubscription? exitSubscription;

    final isolate =
        await Isolate.spawn<Map<String, Object>>(_extractBundleFilesIsolate, {
          'sendPort': receivePort.sendPort,
          'tmpPath': tmpPath,
          'destDir': destDir,
          'markerPath': markerPath,
          'expectedSourceCount': expectedSourceCount,
        }, onExit: exitPort.sendPort);

    try {
      progressSubscription = receivePort.listen((message) {
        if (message is! Map) {
          return;
        }
        final type = message['type']?.toString();
        if (type == 'progress') {
          if (!mounted) {
            return;
          }
          final stage = message['stage']?.toString() ?? _bundleStageExtracting;
          final current = (message['current'] as num?)?.toInt() ?? 0;
          final total = (message['total'] as num?)?.toInt() ?? 1;
          setState(() {
            download.setFinalizingProgress(
              stage,
              nextCurrent: current,
              nextTotal: total,
            );
          });
          return;
        }
        if (type == 'done' && !completion.isCompleted) {
          completion.complete();
          return;
        }
        if (type == 'error' && !completion.isCompleted) {
          completion.completeError(
            StateError(
              message['error']?.toString() ?? 'Bundle extraction failed',
            ),
          );
        }
      });

      exitSubscription = exitPort.listen((_) {
        if (!completion.isCompleted) {
          completion.completeError(
            StateError('Bundle extraction stopped before finishing'),
          );
        }
      });

      await completion.future;
    } finally {
      await progressSubscription?.cancel();
      await exitSubscription?.cancel();
      receivePort.close();
      exitPort.close();
      isolate.kill(priority: Isolate.immediate);
    }
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

  List<_StartupDownloadItem> _startupDownloads(AppLocalizations l10n) => [
    _StartupDownloadItem(
      key: "gemma-4-E4B-it.litertlm",
      title: l10n.introAssetGemmaTitle,
      subtitle: l10n.introAssetGemmaSubtitle,
      sizeLabel: "3.65 GB",
    ),
    _StartupDownloadItem(
      key: "Gecko_1024_quant.tflite",
      title: l10n.introAssetGeckoTitle,
      subtitle: l10n.introAssetGeckoSubtitle,
      sizeLabel: "146 MB",
    ),
    _StartupDownloadItem(
      key: "sentencepiece.model",
      title: l10n.introAssetTokenizerTitle,
      subtitle: l10n.introAssetTokenizerSubtitle,
      sizeLabel: "794 KB",
    ),
    _StartupDownloadItem(
      key: _bundleKey,
      title: l10n.introAssetBundleTitle,
      subtitle: l10n.introAssetBundleSubtitle(_pinnedBundle?.sourceCount ?? 0),
    ),
  ];

  String _formatBytes(num bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final decimals = value >= 100 || unitIndex == 0
        ? 0
        : value >= 10
        ? 1
        : 2;
    return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  String _formatSpeed(double speedBytesPerSecond) =>
      '${_formatBytes(speedBytesPerSecond)}/s';

  String _formatEta(Duration remaining) {
    if (remaining.inHours > 0) {
      final minutes = remaining.inMinutes.remainder(60);
      return minutes > 0
          ? '${remaining.inHours}h ${minutes}m'
          : '${remaining.inHours}h';
    }
    if (remaining.inMinutes > 0) {
      final seconds = remaining.inSeconds.remainder(60);
      return seconds > 0
          ? '${remaining.inMinutes}m ${seconds}s'
          : '${remaining.inMinutes}m';
    }
    return '${remaining.inSeconds}s';
  }

  String _downloadStatus(AppLocalizations l10n, DownloadInProgress? download) {
    if (download == null) {
      return l10n.introDownloadStatusQueued;
    }
    if (download.finished) {
      return l10n.introDownloadStatusReady;
    }
    if (download.finalizing) {
      switch (download.stage) {
        case _bundleStageDecompressing:
          return l10n.introDownloadStatusDecompressing;
        case _bundleStageScanning:
          return l10n.introDownloadStatusScanning;
        case _bundleStageVerifying:
          return l10n.introDownloadStatusVerifying;
        case _bundleStageExtracting:
        default:
          return l10n.introDownloadStatusExtracting;
      }
    }
    if (download.total > 0 && download.current > 0) {
      final percent = ((download.current / download.total) * 100)
          .clamp(0, 100)
          .toStringAsFixed(0);
      return '$percent%';
    }
    return l10n.introDownloadStatusStarting;
  }

  String? _downloadDetails(
    AppLocalizations l10n,
    String itemKey,
    DownloadInProgress? download,
  ) {
    if (download == null || download.finished) {
      return null;
    }

    if (download.finalizing) {
      if (itemKey != _bundleKey) {
        return null;
      }
      switch (download.stage) {
        case _bundleStageDecompressing:
          return l10n.introDownloadBundleDecompressing(
            _formatBytes(download.current),
            _formatBytes(download.total),
          );
        case _bundleStageScanning:
          return l10n.introDownloadBundleScanning;
        case _bundleStageVerifying:
          return l10n.introDownloadBundleVerifying(
            _pinnedBundle?.sourceCount ?? 0,
          );
        case _bundleStageExtracting:
        default:
          return l10n.introDownloadBundleExtracting(
            _formatBytes(download.current),
            _formatBytes(download.total),
          );
      }
    }

    final parts = <String>[
      '${_formatBytes(download.current)} / ${_formatBytes(download.total)}',
    ];
    if (download.displayedSpeedBytesPerSecond > 0) {
      parts.add(_formatSpeed(download.displayedSpeedBytesPerSecond));
    }
    if (download.displayedEta != null) {
      parts.add(
        l10n.introDownloadFinishesIn(_formatEta(download.displayedEta!)),
      );
    }
    return parts.join(' • ');
  }

  Widget _buildDownloadChecklist(AppLocalizations l10n) {
    final items = _startupDownloads(l10n);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE8D1CB)),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.introDownloadIncludesTitle,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xff5A382F),
            ),
          ),
          const SizedBox(height: 12),
          for (final item in items)
            Builder(
              builder: (context) {
                final download = downloads[item.key];
                final itemProgress = download == null || download.total <= 0
                    ? 0.0
                    : download.current / download.total;
                final details = _downloadDetails(l10n, item.key, download);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  item.subtitle,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (item.sizeLabel != null)
                                Text(
                                  item.sizeLabel!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: download?.finished == true
                                      ? const Color(0xFFDDF3E5)
                                      : download?.finalizing == true
                                      ? const Color(0xFFFFEACC)
                                      : const Color(0xFFF4EFED),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  _downloadStatus(l10n, download),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: download?.finished == true
                                        ? const Color(0xFF1C6B3A)
                                        : download?.finalizing == true
                                        ? const Color(0xFF8B5A00)
                                        : const Color(0xff6B5851),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (download != null && !download.finished) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: itemProgress.clamp(0.0, 1.0),
                          color: const Color(0xffDE7356),
                          backgroundColor: const Color(0xFFF3E2DC),
                        ),
                        if (details != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            details,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[600],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

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
      nextButton = Column(
        children: [
          _buildDownloadChecklist(l10n),
          const SizedBox(height: 16),
          ElevatedButton(
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
          ),
        ],
      );
    } else {
      nextButton = _buildDownloadChecklist(l10n);
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

Future<void> _extractBundleFilesIsolate(Map<String, Object> args) async {
  final sendPort = args['sendPort']! as SendPort;
  final tmpPath = args['tmpPath']! as String;
  final destDir = args['destDir']! as String;
  final markerPath = args['markerPath']! as String;
  final expectedSourceCount =
      (args['expectedSourceCount'] as num?)?.toInt() ?? 0;

  try {
    // ── Phase 1: Decompress gzip → temp tar file ─────────────────────────
    // Stream decompression to disk rather than accumulating in memory.
    final tmpTarPath = '$tmpPath.tar';
    final compressedFile = io.File(tmpPath);
    final compressedSize = await compressedFile.length();
    var compressedRead = 0;
    var lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);

    final tarSink = io.File(tmpTarPath).openWrite();
    await compressedFile
        .openRead()
        .transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, sink) {
              compressedRead += chunk.length;
              _sendBundleExtractProgress(
                sendPort,
                stage: _bundleStageDecompressing,
                current: compressedRead,
                total: compressedSize,
                lastReportAt: lastReportAt,
                updateLastReportAt: (value) => lastReportAt = value,
              );
              sink.add(chunk);
            },
          ),
        )
        .transform(io.gzip.decoder)
        .pipe(tarSink);

    _forceBundleExtractProgress(
      sendPort,
      stage: _bundleStageDecompressing,
      current: compressedSize,
      total: compressedSize,
    );

    compressedFile.deleteSync(); // free space before extracting

    // ── Phase 2: Stream tar entries → write files directly ────────────────
    // Parse the tar file entry-by-entry using a manual 512-byte block parser.
    // Each wanted file is written directly to its destination without loading
    // the full archive into memory.
    final tarFile = io.File(tmpTarPath);
    final tarSize = tarFile.lengthSync();

    _forceBundleExtractProgress(
      sendPort,
      stage: _bundleStageExtracting,
      current: 0,
      total: tarSize,
    );

    var tarBytesProcessed = 0;
    var pdfCount = 0;
    var foundEmbeddings = false;
    lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);

    final raf = tarFile.openSync();
    try {
      const blockSize = 512;
      final headerBuf = Uint8List(blockSize);
      var consecutiveZeroBlocks = 0;
      String? gnuLongName;

      while (true) {
        final bytesRead = raf.readIntoSync(headerBuf);
        if (bytesRead < blockSize) break;
        tarBytesProcessed += blockSize;

        // Two consecutive all-zero blocks mark end-of-archive.
        var isZeroBlock = true;
        for (var i = 0; i < blockSize; i++) {
          if (headerBuf[i] != 0) {
            isZeroBlock = false;
            break;
          }
        }
        if (isZeroBlock) {
          consecutiveZeroBlocks++;
          if (consecutiveZeroBlocks >= 2) break;
          continue;
        }
        consecutiveZeroBlocks = 0;

        // Parse POSIX ustar header fields.
        String name = _readTarString(headerBuf, 0, 100);
        final prefix = _readTarString(headerBuf, 345, 155);
        if (prefix.isNotEmpty) name = '$prefix/$name';

        final sizeField = _readTarString(headerBuf, 124, 12).trim();
        final typeFlag = headerBuf[156];
        final size = sizeField.isEmpty ? 0 : int.parse(sizeField, radix: 8);
        final contentBlocks = (size + blockSize - 1) ~/ blockSize;

        // GNU long-name extension: content is the real name for the next entry.
        if (typeFlag == 76 /* 'L' */) {
          final nameBuf = Uint8List(contentBlocks * blockSize);
          raf.readIntoSync(nameBuf);
          tarBytesProcessed += contentBlocks * blockSize;
          gnuLongName = _readTarString(nameBuf, 0, size);
          continue;
        }

        final effectiveName = gnuLongName ?? name;
        gnuLongName = null;

        // Only regular files (type '0' or legacy NUL) are extracted.
        final isRegularFile = typeFlag == 48 /* '0' */ || typeFlag == 0;
        final destPath =
            isRegularFile ? _bundleDestPath(destDir, effectiveName) : null;

        if (destPath != null && size > 0) {
          final outSink = io.File(destPath).openWrite();
          var remaining = size;
          final dataBuf = Uint8List(blockSize);
          for (var i = 0; i < contentBlocks; i++) {
            raf.readIntoSync(dataBuf);
            tarBytesProcessed += blockSize;
            final toWrite = remaining < blockSize ? remaining : blockSize;
            outSink.add(dataBuf.sublist(0, toWrite));
            remaining -= toWrite;
          }
          await outSink.flush();
          await outSink.close();

          if (destPath.endsWith('embeddings.sqlite')) {
            foundEmbeddings = true;
          } else if (destPath.toLowerCase().endsWith('.pdf')) {
            pdfCount++;
          }
        } else {
          // Skip unwanted content blocks.
          raf.setPositionSync(raf.positionSync() + contentBlocks * blockSize);
          tarBytesProcessed += contentBlocks * blockSize;
        }

        _sendBundleExtractProgress(
          sendPort,
          stage: _bundleStageExtracting,
          current: tarBytesProcessed,
          total: tarSize,
          lastReportAt: lastReportAt,
          updateLastReportAt: (value) => lastReportAt = value,
        );
      }
    } finally {
      raf.closeSync();
    }

    _forceBundleExtractProgress(
      sendPort,
      stage: _bundleStageExtracting,
      current: tarSize,
      total: tarSize,
    );

    // ── Phase 3: Verify ──────────────────────────────────────────────────
    _forceBundleExtractProgress(
      sendPort,
      stage: _bundleStageVerifying,
      current: 0,
      total: 1,
    );

    tarFile.deleteSync();

    if (!foundEmbeddings) {
      throw StateError('RAG bundle did not contain embeddings.sqlite');
    }
    if (expectedSourceCount > 0 && pdfCount != expectedSourceCount) {
      throw StateError(
        'RAG bundle PDF count mismatch: expected $expectedSourceCount, got $pdfCount',
      );
    }
    io.File(markerPath).writeAsStringSync('ok');
    _forceBundleExtractProgress(
      sendPort,
      stage: _bundleStageVerifying,
      current: 1,
      total: 1,
    );
    sendPort.send({'type': 'done'});
  } catch (e, st) {
    sendPort.send({'type': 'error', 'error': '$e\n$st'});
  }
}

String? _bundleDestPath(String destDir, String sourceName) {
  if (sourceName.contains('runtime/') &&
      sourceName.endsWith('embeddings.sqlite')) {
    return '$destDir/embeddings.sqlite';
  }
  if (sourceName.contains('/docs/') && sourceName.endsWith('.pdf')) {
    return '$destDir/${sourceName.split('/').last}';
  }
  return null;
}

/// Reads a null-terminated ASCII/UTF-8 string from [buf] at [offset]..[offset+length].
String _readTarString(Uint8List buf, int offset, int length) {
  var end = offset;
  final limit = offset + length;
  while (end < limit && buf[end] != 0) {
    end++;
  }
  return utf8.decode(buf.sublist(offset, end), allowMalformed: true);
}

void _sendBundleExtractProgress(
  SendPort sendPort, {
  required String stage,
  required int current,
  required int total,
  required DateTime lastReportAt,
  required void Function(DateTime value) updateLastReportAt,
}) {
  final now = DateTime.now();
  if (now.difference(lastReportAt).inMilliseconds < 250 && current < total) {
    return;
  }
  updateLastReportAt(now);
  _forceBundleExtractProgress(
    sendPort,
    stage: stage,
    current: current,
    total: total,
  );
}

void _forceBundleExtractProgress(
  SendPort sendPort, {
  required String stage,
  required int current,
  required int total,
}) {
  sendPort.send({
    'type': 'progress',
    'stage': stage,
    'current': current < 0 ? 0 : current,
    'total': total <= 0 ? 1 : total,
  });
}

Future<bool?> promptLicense(BuildContext context, AppLocalizations l10n) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text(l10n.licenseTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.licenseIntro),
              const SizedBox(height: 30),
              Text(l10n.licenseTermsText),
              const SizedBox(height: 15),
              InkWell(
                child: const Padding(
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
                  launchUrlString("https://ai.google.dev/gemma/terms");
                },
              ),
              InkWell(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    l10n.licenseUsagePolicyLink,
                    style: const TextStyle(
                      color: Colors.blue,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
                onTap: () {
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
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.licenseAccept),
          ),
          TextButton(
            style: TextButton.styleFrom(
              textStyle: Theme.of(context).textTheme.labelLarge,
            ),
            child: Text(l10n.licenseDeny),
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
      );
    },
  );
}

class DownloadInProgress {
  int total;
  int current;
  bool finished;
  bool finalizing;
  String? stage;
  final DateTime startedAt;
  DateTime? _lastProgressAt;
  DateTime? _lastDisplayUpdateAt;
  int _lastProgressBytes;
  double speedBytesPerSecond;
  double displayedSpeedBytesPerSecond;
  Duration? displayedEta;

  DownloadInProgress({
    required this.total,
    required this.current,
    required this.finished,
    this.finalizing = false,
    this.stage,
    DateTime? startedAt,
    this.speedBytesPerSecond = 0,
    this.displayedSpeedBytesPerSecond = 0,
    this.displayedEta,
  }) : startedAt = startedAt ?? DateTime.now(),
       _lastProgressBytes = current;

  void updateProgress(int nextCurrent, int nextTotal) {
    final now = DateTime.now();
    final safeTotal = nextTotal > 0 ? nextTotal : total;
    final safeCurrent = nextCurrent < 0 ? 0 : nextCurrent;

    if (_lastProgressAt != null) {
      final elapsedMs = now.difference(_lastProgressAt!).inMilliseconds;
      final deltaBytes = safeCurrent - _lastProgressBytes;
      if (elapsedMs > 0 && deltaBytes >= 0) {
        final instantSpeed = (deltaBytes * 1000) / elapsedMs;
        speedBytesPerSecond = speedBytesPerSecond == 0
            ? instantSpeed
            : (speedBytesPerSecond * 0.75) + (instantSpeed * 0.25);
      }
    }

    total = safeTotal;
    current = safeCurrent > safeTotal ? safeTotal : safeCurrent;
    _lastProgressAt = now;
    _lastProgressBytes = current;

    final shouldRefreshDisplay =
        _lastDisplayUpdateAt == null ||
        now.difference(_lastDisplayUpdateAt!).inMilliseconds >= 1000 ||
        current >= total;
    if (shouldRefreshDisplay) {
      displayedSpeedBytesPerSecond = speedBytesPerSecond;
      if (displayedSpeedBytesPerSecond > 0 && total > 0 && current < total) {
        final remainingSeconds =
            ((total - current) / displayedSpeedBytesPerSecond).ceil();
        displayedEta = Duration(
          seconds: remainingSeconds <= 0 ? 1 : remainingSeconds,
        );
      } else {
        displayedEta = null;
      }
      _lastDisplayUpdateAt = now;
    }
  }

  void setFinalizingProgress(
    String nextStage, {
    required int nextCurrent,
    required int nextTotal,
  }) {
    finalizing = true;
    stage = nextStage;
    current = nextCurrent < 0 ? 0 : nextCurrent;
    total = nextTotal <= 0 ? 1 : nextTotal;
    displayedEta = null;
    displayedSpeedBytesPerSecond = 0;
  }
}


class _StartupDownloadItem {
  final String key;
  final String title;
  final String subtitle;
  final String? sizeLabel;

  const _StartupDownloadItem({
    required this.key,
    required this.title,
    required this.subtitle,
    this.sizeLabel,
  });
}
