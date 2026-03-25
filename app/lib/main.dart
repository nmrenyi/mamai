import 'package:app/locale_notifier.dart';
import 'package:app/screens/search_page.dart';
import 'package:app/screens/intro_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:app/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Restore persisted language preference (defaults to English).
  final prefs = await SharedPreferences.getInstance();
  final langCode = prefs.getString('locale') ?? 'en';
  appLocale.value = Locale(langCode);
  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: appLocale,
      builder: (_, locale, __) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'MAM-AI',
          locale: locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            colorSchemeSeed: Color(0xffcc5500),
            useMaterial3: true,
            textTheme: TextTheme(
              bodyMedium: TextStyle(fontSize: 18, height: 1.5),
              labelLarge: TextStyle(letterSpacing: 1.2, fontSize: 20),
            ),
          ),
          home: const IntroPage(),
          routes: {'/chat': (context) => const SearchPage()},
        );
      },
    );
  }
}
