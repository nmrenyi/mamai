import 'package:flutter/material.dart';

/// Global locale notifier — the single source of truth for the app language.
/// Persisted to SharedPreferences in main.dart on change.
final ValueNotifier<Locale> appLocale = ValueNotifier(const Locale('en'));
