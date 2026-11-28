#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

channel=${READER_CHANNEL:-dev}
build_number=${READER_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
commit_sha=${READER_COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo dev)}
short_sha=$(printf '%s' "$commit_sha" | cut -c1-7)
built_at=${READER_BUILT_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}
base_version=${READER_BASE_VERSION:-$(awk -F'"' '/MARKETING_VERSION:/{print $2; exit}' project.yml 2>/dev/null || echo 1.0)}
version="${base_version}-${channel}.${build_number}+${short_sha}"
arch=$(uname -m)
out_dir=${READER_DIST_DIR:-"$repo_root/dist"}
codesign_identity=${READER_CODESIGN_IDENTITY:--}

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required (brew install xcodegen)" >&2
    exit 1
fi

derived_data=$(mktemp -d "${TMPDIR:-/tmp}/reader-build.XXXXXX")
cleanup() {
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$derived_data/Build/Products/Release/Reader.app" >/dev/null 2>&1 || true
    rm -rf "$derived_data"
}
trap cleanup EXIT

xcodegen generate

xcodebuild \
    -project Reader.xcodeproj \
    -scheme Reader \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    ARCHS="$arch" \
    ONLY_ACTIVE_ARCH=YES \
    MARKETING_VERSION="$base_version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$codesign_identity" \
    build

built_app="$derived_data/Build/Products/Release/Reader.app"
if [ ! -d "$built_app" ]; then
    echo "Expected built app at $built_app" >&2
    exit 1
fi

mkdir -p "$out_dir"
app_bundle="$out_dir/Reader.app"
rm -rf "$app_bundle"
/usr/bin/ditto "$built_app" "$app_bundle"

plist="$app_bundle/Contents/Info.plist"
set_plist_string() {
    key=$1
    val=$2
    /usr/libexec/PlistBuddy -c "Set :${key} ${val}" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :${key} string ${val}" "$plist"
}

set_plist_string "CFBundleShortVersionString" "$base_version"
set_plist_string "CFBundleVersion" "$build_number"
set_plist_string "ReaderChannel" "$channel"
set_plist_string "ReaderCommitSHA" "$commit_sha"
set_plist_string "ReaderBuiltAt" "$built_at"
set_plist_string "ReaderVersion" "$version"

codesign --force --deep --options runtime \
    --entitlements "$repo_root/App/Reader/Reader.entitlements" \
    --sign "$codesign_identity" \
    "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

zip_path="$out_dir/Reader-macos-${arch}-${short_sha}.zip"
rm -f "$zip_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$zip_path"

echo "Packaged $app_bundle ($version)"
echo "Archive $zip_path"
