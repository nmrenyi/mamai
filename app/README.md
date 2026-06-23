# MAM-AI

A clinical decision-support tool for nurse-midwives in Zanzibar. Provides fully offline, on-device answers grounded in medical guidelines — covering maternal health, obstetrics, and neonatal care.

## Requirements

### Android device

| Requirement | Minimum |
|---|---|
| Android version | 7.0 (API 24) |
| Architecture | arm64-v8a (64-bit) |

> **Why API 24?** The LiteRT-LM Android runtime used for on-device Gemma 4 requires Android 7.0+.

> **Real device required.** The on-device LiteRT-LM stack is intended for physical Android hardware, not emulators.

### Development machine

- Flutter SDK (see `pubspec.yaml` for SDK constraint)
- Android SDK with platform-tools (`adb` in PATH or at `~/Library/Android/sdk/platform-tools/`)

## Building and running

```bash
cd app
flutter pub get

# Run on a connected Android device
flutter run

# Build a release APK
flutter build apk
```

For signed local release builds, copy
[`android/key.properties.example`](android/key.properties.example)
to `app/android/key.properties` and fill in your keystore values. CI stage
releases use the same fields via GitHub secrets.

## Language

The app is **English only**. (Swahili was removed — the deployed clinical prompt
was validated in English only, and shipping an un-validated Swahili translation of
a safety-critical prompt is out of scope.)
