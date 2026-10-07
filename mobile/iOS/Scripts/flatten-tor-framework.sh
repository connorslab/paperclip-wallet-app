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
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "${tor_bundle}"
    fi
fi
