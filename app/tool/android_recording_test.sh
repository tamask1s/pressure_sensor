#!/usr/bin/env bash
set -euo pipefail
trap 'adb logcat -d > build/android-recording-logcat.txt' EXIT
adb install -r -g build/app/outputs/flutter-apk/app-debug.apk
flutter test --no-pub -d emulator-5554 integration_test/recording_test.dart --reporter expanded 2>&1 | tee build/android-recording-test.txt
