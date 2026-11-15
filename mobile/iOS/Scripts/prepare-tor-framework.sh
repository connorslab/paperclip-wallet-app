#!/bin/bash
set -euo pipefail
# Normalize the pinned dependency before Xcode copies, generates a stub, or signs it.
# Editing the embedded framework in a build phase races those Xcode tasks.
script_dir=$(cd "$(dirname "$0")" && pwd)
artifact_dir="$script_dir/../../TorRuntime/Artifacts"
digest=851174402abc8655273264f6b877a625648e52e6f9dd490b35e7cb94c2c924c6
revision="$digest-flat-ios-v2"
if [[ -f "$artifact_dir/prepared-version" && $(cat "$artifact_dir/prepared-version") == "$revision" && -f "$artifact_dir/tor.xcframework/Info.plist" ]]; then
    exit 0
fi
mkdir -p "$artifact_dir"
archive="$artifact_dir/tor.xcframework.zip"
if [[ ! -f "$archive" ]]; then
    swift_cache="$HOME/Library/Caches/org.swift.swiftpm/artifacts/https___github_com_iCepa_Tor_framework_releases_download_v409_13_1_tor_xcframework_zip"
    if [[ -f "$swift_cache" ]]; then
        cp "$swift_cache" "$archive"
    else
        curl --fail --location --retry 3 --output "$archive.partial" \
            https://github.com/iCepa/Tor.framework/releases/download/v409.13.1/tor.xcframework.zip
        mv "$archive.partial" "$archive"
    fi
fi
[[ $(shasum -a 256 "$archive" | cut -d ' ' -f 1) == "$digest" ]] || { echo 'error: Tor archive checksum mismatch' >&2; exit 1; }
staging=$(mktemp -d "$artifact_dir/prepare.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto -x -k "$archive" "$staging"
python3 - "$staging/tor.xcframework" <<'PY'
import pathlib, plistlib, shutil, sys
root = pathlib.Path(sys.argv[1])
with (root / 'Info.plist').open('rb') as f:
    manifest = plistlib.load(f)
libraries = manifest['AvailableLibraries']
for library in libraries:
    if library['SupportedPlatform'] != 'ios':
        continue
    framework = root / library['LibraryIdentifier'] / library['LibraryPath']
    version = framework / 'Versions/Current'
    # Materialize all resources and public headers; leave macOS slices unchanged.
    flat = framework.with_suffix('.flat')
    flat.mkdir()
    for item in version.iterdir():
        if item.name == '_CodeSignature':
            continue
        if item.name == 'Resources':
            shutil.copytree(item, flat, dirs_exist_ok=True)
        elif item.is_dir():
            shutil.copytree(item, flat / item.name)
        else:
            shutil.copy2(item, flat / item.name)
    info = flat / 'Info.plist'
    with info.open('rb') as f:
        metadata = plistlib.load(f)
    metadata['CFBundleShortVersionString'] = '4.9.13'
    metadata['CFBundleVersion'] = '4.9.13'
    metadata['CFBundleSupportedPlatforms'] = ['iPhoneSimulator' if library.get('SupportedPlatformVariant') == 'simulator' else 'iPhoneOS']
    with info.open('wb') as f:
        plistlib.dump(metadata, f)
    shutil.rmtree(framework)
    flat.rename(framework)
    library['BinaryPath'] = library['LibraryPath'] + '/tor'
with (root / 'Info.plist').open('wb') as f:
    plistlib.dump(manifest, f)
signature = root / '_CodeSignature'
if signature.exists():
    shutil.rmtree(signature)
PY
rm -rf "$artifact_dir/tor.xcframework"
mv "$staging/tor.xcframework" "$artifact_dir/tor.xcframework"
printf '%s\n' "$revision" > "$artifact_dir/prepared-version"
echo 'Prepared checksum-verified Tor framework with flat iOS bundles'
