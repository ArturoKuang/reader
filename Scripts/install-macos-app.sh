#!/bin/sh
set -eu

repo=${READER_REPO:-ArturoKuang/reader}
tag=${1:-main-latest}
install_dir=${READER_APP_DIR:-"$HOME/Applications"}
public_key=${READER_UPDATE_PUBLIC_KEY:-"vu0lKVXUkj0Mwdq+MxQSlshl9UFc+vMZwrFbMj5SLd8="}
arch=$(uname -m)
artifact_key="macos-app-${arch}"

manifest_url="https://github.com/${repo}/releases/download/${tag}/manifest.json"
sig_url="${manifest_url}.sig"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

curl -fsSL "$manifest_url" -o "$tmp_dir/manifest.json"
curl -fsSL "$sig_url" -o "$tmp_dir/manifest.json.sig"

if command -v swift >/dev/null 2>&1; then
    swift - "$tmp_dir/manifest.json" "$tmp_dir/manifest.json.sig" "$public_key" <<'SWIFT'
import CryptoKit
import Foundation

let args = CommandLine.arguments
let manifest = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let sigText = try String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let pubData = Data(base64Encoded: args[3]),
      let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
      let sigData = Data(base64Encoded: sigText),
      pubKey.isValidSignature(sigData, for: manifest) else {
    fputs("Manifest signature verification failed.\n", stderr)
    exit(1)
}
SWIFT
elif [ "${READER_ALLOW_UNVERIFIED_SIG:-0}" != "1" ]; then
    echo "swift not found to verify Ed25519 signature. Install Xcode Command Line Tools or set READER_ALLOW_UNVERIFIED_SIG=1." >&2
    exit 1
fi

artifact_info=$(/usr/bin/python3 - "$tmp_dir/manifest.json" "$artifact_key" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
art = data["artifacts"][sys.argv[2]]
print(art["url"])
print(art["sha256"])
print(data["version"])
PY
)
download_url=$(printf '%s\n' "$artifact_info" | sed -n '1p')
expected_sha=$(printf '%s\n' "$artifact_info" | sed -n '2p')
version=$(printf '%s\n' "$artifact_info" | sed -n '3p')

echo "Downloading Reader ${version} (${artifact_key})..."
curl -fsSL "$download_url" -o "$tmp_dir/Reader.zip"
actual_sha=$(shasum -a 256 "$tmp_dir/Reader.zip" | awk '{print $1}')
if [ "$actual_sha" != "$expected_sha" ]; then
    echo "Checksum mismatch: expected $expected_sha, got $actual_sha" >&2
    exit 1
fi

/usr/bin/ditto -x -k "$tmp_dir/Reader.zip" "$tmp_dir/extracted"
xattr -dr com.apple.quarantine "$tmp_dir/extracted/Reader.app" 2>/dev/null || true
codesign --verify --deep "$tmp_dir/extracted/Reader.app"

mkdir -p "$install_dir"
target_app="$install_dir/Reader.app"
backup_app="$install_dir/.Reader.app.backup"

osascript -e 'tell application id "com.reader.Reader" to quit' 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f 'Reader.app/Contents/MacOS/Reader' >/dev/null || break
    sleep 0.2
done

rm -rf "$backup_app"
if [ -e "$target_app" ]; then
    mv "$target_app" "$backup_app"
fi
if ! mv "$tmp_dir/extracted/Reader.app" "$target_app" 2>/dev/null; then
    /usr/bin/ditto "$tmp_dir/extracted/Reader.app" "$target_app"
fi
rm -rf "$backup_app"

echo "Installed Reader ${version} -> ${target_app}"
if [ "${READER_NO_LAUNCH:-0}" != "1" ]; then
    /usr/bin/open -n "$target_app"
fi
