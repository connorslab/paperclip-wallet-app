#!/usr/bin/env bash
set -euo pipefail
android_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$android_dir"
# Keep evidence from all classes, including the first failure.
mkdir -p app/build/reports/instrumentation
trap 'adb pull /sdcard/Pictures/PaperclipPreview ./screenshots >/dev/null 2>&1 || true' EXIT
adb shell cmd uimode night yes
for test in SecureStoreRecoveryTest PaymentSettingsStorageTest NativeBridgeTest PublicWalletNativeTest AssistanceNativeTest WalletProfilesNativeTest WalletSelectionStateTest BackupLifecycleTest WalletHealthLayoutTest BridgeHealthLayoutTest BridgeFlowLayoutTest JoinBlaketLayoutTest PaymentFlowLayoutTest NodeLayoutTest SeedGenerationLayoutTest AdaptiveLayoutTest WalletScreensTest WalletSettingsScreensTest; do
    result=0
    started=$(date +%s)
    bash gradlew --no-daemon "-Pabis=${PAPERCLIP_TEST_ABI:-x86_64}" \
        "-Pandroid.testInstrumentationRunnerArguments.class=xyz.paperclip.wallet.$test" \
        connectedDebugAndroidTest || result=$?
    if [[ -d app/build/reports/androidTests ]]; then
        mkdir -p "app/build/reports/instrumentation/$test"
        cp -R app/build/reports/androidTests/. "app/build/reports/instrumentation/$test/"
    fi
    if (( result != 0 )); then exit "$result"; fi
    # Some runner/filter combinations can exit successfully after executing only
    # one requested class. Keep one class per run and verify the actual evidence.
    python3 scripts/verify-instrumentation.py app/build/outputs/androidTest-results/connected \
        "xyz.paperclip.wallet.$test" "$started"
done
