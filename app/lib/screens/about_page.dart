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

  @override
  void initState() {
    super.initState();
    _bundleInfoFuture = _loadBundleInfo();
  }

  Future<RagBundleInfo?> _loadBundleInfo() async {
    try {
      final raw = await _platform.invokeMapMethod<String, dynamic>(
        "getDeployedRagBundleInfo",
      );
      if (raw == null) return null;
      return RagBundleInfo.fromMap(raw);
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

class RagBundleInfo {
  final String bundleVersion;
  final String deployedAtUtc;

  const RagBundleInfo({
    required this.bundleVersion,
    required this.deployedAtUtc,
  });

  factory RagBundleInfo.fromMap(Map<String, dynamic> raw) {
    return RagBundleInfo(
      bundleVersion: raw['bundleVersion']?.toString() ?? '',
      deployedAtUtc: raw['deployedAtUtc']?.toString() ?? '',
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
