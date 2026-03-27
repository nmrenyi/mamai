import 'package:flutter/material.dart';
import 'package:app/l10n/app_localizations.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

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
