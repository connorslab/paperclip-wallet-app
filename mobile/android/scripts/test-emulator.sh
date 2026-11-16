#!/usr/bin/env bash
set -euo pipefail
android_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$android_dir"
# Keep evidence from all classes, including the first failure.
mkdir -p app/build/reports/instrumentation
trap 'adb pull /sdcard/Pictures/PaperclipPreview ./screenshots >/dev/null 2>&1 || true' EXIT
adb shell cmd uimode night yes
for test in NativeBridgeTest PublicWalletNativeTest AssistanceNativeTest WalletHealthLayoutTest BridgeHealthLayoutTest BridgeFlowLayoutTest AdaptiveLayoutTest WalletScreensTest WalletSettingsScreensTest; do
    result=0
    bash gradlew --no-daemon "-Pabis=${PAPERCLIP_TEST_ABI:-x86_64}" \
        "-Pandroid.testInstrumentationRunnerArguments.class=xyz.paperclip.wallet.$test" \
        connectedDebugAndroidTest || result=$?
    if [[ -d app/build/reports/androidTests ]]; then
        mkdir -p "app/build/reports/instrumentation/$test"
        cp -R app/build/reports/androidTests/. "app/build/reports/instrumentation/$test/"
    fi
    if (( result != 0 )); then exit "$result"; fi
done
