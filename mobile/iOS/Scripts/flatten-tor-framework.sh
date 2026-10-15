#!/bin/bash
set -euo pipefail
# The pinned upstream XCFramework uses a macOS-style versioned bundle for iOS.
# Flatten only the copied app artifact, then sign it again for the selected team.
tor_bundle="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/tor.framework"
if [[ -d "${tor_bundle}/Versions" ]]; then
    ditto "${tor_bundle}/Versions/Current/tor" "${tor_bundle}/tor.flat"
    ditto "${tor_bundle}/Versions/Current/Resources/Info.plist" "${tor_bundle}/Info.plist"
    rm "${tor_bundle}/tor"
    mv "${tor_bundle}/tor.flat" "${tor_bundle}/tor"
    rm -rf "${tor_bundle}/Versions" "${tor_bundle}/Resources" "${tor_bundle}/_CodeSignature"
fi
if [[ -d "${tor_bundle}" ]]; then
    # Upstream's four-part version is not accepted by App Store Connect.
    /usr/bin/plutil -replace CFBundleShortVersionString -string "4.9.13" "${tor_bundle}/Info.plist"
    /usr/bin/plutil -replace CFBundleVersion -string "4.9.13" "${tor_bundle}/Info.plist"
    /usr/bin/plutil -replace MinimumOSVersion -string "${IPHONEOS_DEPLOYMENT_TARGET}" "${tor_bundle}/Info.plist"
    /usr/bin/plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "${tor_bundle}/Info.plist"
    # Xcode's static-framework stub can retain a designated requirement for
    # identifier "tor". Recreate it using the actual bundle identifier before
    # distribution export preserves/re-signs the embedded framework.
    /usr/bin/codesign --remove-signature "${tor_bundle}/tor"
    tor_identity="-"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
        tor_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    fi
    /usr/bin/codesign --force --sign "${tor_identity}" --identifier org.torproject.tor --timestamp=none "${tor_bundle}"
fi
