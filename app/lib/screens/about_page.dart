import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:app/l10n/app_localizations.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const _platform = MethodChannel(
    "io.github.mzsfighters.mam_ai/request_generation",
  );

  late final Future<RagBundleInfo?> _bundleInfoFuture;
  late final Future<RuntimeInfo?> _runtimeInfoFuture;

  @override
  void initState() {
    super.initState();
    _bundleInfoFuture = _loadBundleInfo();
    _runtimeInfoFuture = _loadRuntimeInfo();
  }

  Future<RagBundleInfo?> _loadBundleInfo() async {
    final deployed = await _invokeMap("getDeployedRagBundleInfo");
    if (deployed != null) {
      return RagBundleInfo.fromMap(deployed, source: BundleInfoSource.deployed);
    }
    final pinned = await _invokeMap("getPinnedRagBundleInfo");
    if (pinned != null) {
      return RagBundleInfo.fromMap(pinned, source: BundleInfoSource.pinned);
    }
    return null;
  }

  Future<RuntimeInfo?> _loadRuntimeInfo() async {
    final raw = await _invokeMap("getRuntimeInfo");
    if (raw == null) return null;
    return RuntimeInfo.fromMap(raw);
  }

  Future<Map<String, dynamic>?> _invokeMap(String method) async {
    try {
      return await _platform.invokeMapMethod<String, dynamic>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    const orange = Color(0xffDE7356);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aboutTitle),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Logo
            Image.asset('images/logo.png', width: 80, height: 80),
            const SizedBox(height: 16),
            const Text(
              'MAM-AI',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: orange,
              ),
            ),
            const SizedBox(height: 20),

            // Description
            Text(
              l10n.aboutDescription,
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey[700],
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 36),
            _BundleInfoCard(bundleInfoFuture: _bundleInfoFuture),
            const SizedBox(height: 16),
            _RuntimeInfoCard(runtimeInfoFuture: _runtimeInfoFuture),
            const SizedBox(height: 36),

            // Partnership
            Text(
              l10n.introPartnership,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey[500],
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 24,
              runSpacing: 16,
              children: [
                Image.asset('images/epfl.png', height: 22),
                Image.asset('images/light.png', height: 28),
                Image.asset('images/swiss_tph.png', height: 28),
                Image.asset('images/d-tree.jpg', height: 28),
              ],
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

enum BundleInfoSource { deployed, pinned }

class RagBundleInfo {
  final String bundleVersion;
  final String deployedAtUtc;
  final BundleInfoSource source;

  const RagBundleInfo({
    required this.bundleVersion,
    required this.deployedAtUtc,
    required this.source,
  });

  factory RagBundleInfo.fromMap(
    Map<String, dynamic> raw, {
    required BundleInfoSource source,
  }) {
    return RagBundleInfo(
      bundleVersion: raw['bundleVersion']?.toString() ?? '',
      deployedAtUtc: raw['deployedAtUtc']?.toString() ?? '',
      source: source,
    );
  }
}

class RuntimeInfo {
  final String appVersion;
  final String litertlmVersion;
  final String llmBackend;

  const RuntimeInfo({
    required this.appVersion,
    required this.litertlmVersion,
    required this.llmBackend,
  });

  factory RuntimeInfo.fromMap(Map<String, dynamic> raw) {
    final name = raw['appVersionName']?.toString() ?? '';
    final code = raw['appVersionCode']?.toString() ?? '';
    final appVersion =
        code.isNotEmpty && name.isNotEmpty ? '$name ($code)' : name;
    return RuntimeInfo(
      appVersion: appVersion,
      litertlmVersion: raw['litertlmVersion']?.toString() ?? '',
      llmBackend: raw['llmBackendConfigured']?.toString() ?? '',
    );
  }
}

class _BundleInfoCard extends StatelessWidget {
  final Future<RagBundleInfo?> bundleInfoFuture;

  const _BundleInfoCard({required this.bundleInfoFuture});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xffF8F5F1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xffE7DED3)),
      ),
      child: FutureBuilder<RagBundleInfo?>(
        future: bundleInfoFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            );
          }

          final info = snapshot.data;
          if (info == null || info.bundleVersion.isEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.aboutKnowledgeBundleTitle,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xff4E4338),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.aboutKnowledgeBundleUnavailable,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xff786A5E),
                    height: 1.5,
                  ),
                ),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.aboutKnowledgeBundleTitle,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff4E4338),
                ),
              ),
              const SizedBox(height: 14),
              _BundleInfoRow(
                label: l10n.aboutKnowledgeBundleVersionLabel,
                value: info.bundleVersion,
              ),
              if (info.deployedAtUtc.isNotEmpty) ...[
                const SizedBox(height: 10),
                _BundleInfoRow(
                  label: l10n.aboutKnowledgeBundleDeployedLabel,
                  value: info.deployedAtUtc,
                ),
              ],
              if (info.source == BundleInfoSource.pinned) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.aboutKnowledgeBundlePinnedNote,
                  style: const TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: Color(0xff786A5E),
                    height: 1.4,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _RuntimeInfoCard extends StatelessWidget {
  final Future<RuntimeInfo?> runtimeInfoFuture;

  const _RuntimeInfoCard({required this.runtimeInfoFuture});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xffF8F5F1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xffE7DED3)),
      ),
      child: FutureBuilder<RuntimeInfo?>(
        future: runtimeInfoFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            );
          }
          final info = snapshot.data;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.aboutRuntimeTitle,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff4E4338),
                ),
              ),
              const SizedBox(height: 14),
              _BundleInfoRow(
                label: l10n.aboutRuntimeAppLabel,
                value: info?.appVersion ?? '—',
              ),
              const SizedBox(height: 10),
              _BundleInfoRow(
                label: l10n.aboutRuntimeLitertlmLabel,
                value: info?.litertlmVersion ?? '—',
              ),
              const SizedBox(height: 10),
              _BundleInfoRow(
                label: l10n.aboutRuntimeBackendLabel,
                value: info?.llmBackend ?? '—',
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BundleInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _BundleInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xff786A5E),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xff2D241C),
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
