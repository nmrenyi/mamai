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

### Cloud AI mode (optional)

The app includes a Cloud AI toggle that uses the Gemini API. To enable it, pass your API key at build/run time:

```bash
flutter run --dart-define=GEMINI_API_KEY=your_key_here
```

Without a key, on-device mode (Gemma 4 E4B) is the default and works fully offline.

## Languages

The app supports English and Swahili. The language toggle is available in the top-right corner of the main screen. Swahili translations are placeholder-quality and pending review by a qualified Swahili-speaking medical professional (see GitHub issue #29).
