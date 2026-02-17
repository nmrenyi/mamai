import 'package:app/screens/search_page.dart';
import 'package:app/screens/intro_page.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mam AI Chat',
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
  }
}
