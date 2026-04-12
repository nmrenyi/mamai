import 'package:flutter/material.dart';

/// Global locale notifier — the single source of truth for the app language.
/// Startup restore happens in main.dart; UI code persists user changes.
final ValueNotifier<Locale> appLocale = ValueNotifier(const Locale('en'));
