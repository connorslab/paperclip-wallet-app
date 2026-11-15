#!/usr/bin/env bash
set -euo pipefail
android_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$android_dir"
adb shell cmd uimode night yes
for test in NativeBridgeTest WalletScreensTest; do
    bash gradlew --no-daemon "-Pabis=${PAPERCLIP_TEST_ABI:-x86_64}" \
        "-Pandroid.testInstrumentationRunnerArguments.class=xyz.paperclip.wallet.$test" \
        connectedDebugAndroidTest
done
adb pull /sdcard/Pictures/PaperclipPreview ./screenshots
