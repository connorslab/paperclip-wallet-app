#!/usr/bin/env bash
set -euo pipefail
android_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$android_dir"
# Only synthetic preview storage on an explicitly selected emulator is touched.
serial=${PAPERCLIP_TEST_SERIAL:-emulator-5554}
[[ "$serial" =~ ^emulator-[0-9]+$ ]] || { echo "Select a disposable emulator" >&2; exit 1; }
[[ "$(adb -s "$serial" shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]] || exit 1
mkdir -p app/build/reports/instrumentation
report_dir=$(mktemp -d app/build/reports/instrumentation/direct-XXXXXXXX)
trap 'adb -s "$serial" pull /sdcard/Pictures/PaperclipPreview ./screenshots >/dev/null 2>&1 || true' EXIT
adb -s "$serial" shell cmd uimode night yes
# APKs are built before the emulator starts. Keep Gradle/compiler memory and
# package install/uninstall churn out of each class's UI acceptance run.
adb -s "$serial" install -r app/build/outputs/apk/debug/app-debug.apk
adb -s "$serial" install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
for test in SecureStoreRecoveryTest PaymentSettingsStorageTest NativeBridgeTest BackupInteropTest PublicWalletNativeTest AssistanceNativeTest WalletProfilesNativeTest WalletSelectionStateTest BackupLifecycleTest WalletHealthLayoutTest BridgeHealthLayoutTest BridgeFlowLayoutTest JoinBlaketLayoutTest PaymentFlowLayoutTest NodeLayoutTest SeedGenerationLayoutTest AdaptiveLayoutTest WalletScreensTest WalletSettingsScreensTest; do

    # Preserve the old per-class fresh-data isolation without removing packages.
    for package in xyz.paperclip.wallet.android.preview xyz.paperclip.wallet.android.preview.test; do
        [[ "$(adb -s "$serial" shell pm clear "$package" | tr -d '\r')" == Success ]] || exit 1
    done
    python3 scripts/run-instrumentation.py "$serial" "xyz.paperclip.wallet.$test" \
        "$report_dir/$test"
done
