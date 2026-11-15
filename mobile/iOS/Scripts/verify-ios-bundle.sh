#!/bin/bash
set -euo pipefail
app_bundle=${1:?Pass the built app bundle}
tor_bundle="$app_bundle/Frameworks/tor.framework"
[[ -f "$app_bundle/Info.plist" && -f "$tor_bundle/Info.plist" && -f "$tor_bundle/tor" ]]
[[ ! -e "$tor_bundle/Versions" && ! -L "$tor_bundle/tor" ]]
app_platform=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$app_bundle/Info.plist")
tor_platform=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$tor_bundle/Info.plist")
[[ "$app_platform" == "$tor_platform" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$tor_bundle/Info.plist") == 4.9.13 ]]
if [[ ${2:-} != --unsigned ]]; then
    /usr/bin/codesign --verify --strict "$tor_bundle"
    /usr/bin/codesign --verify --deep --strict "$app_bundle"
    echo "Verified flat Tor framework, platform metadata, and bundle signatures"
else
    echo "Verified unsigned bundle structure and platform metadata"
fi
