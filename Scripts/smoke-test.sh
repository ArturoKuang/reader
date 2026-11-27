#!/bin/bash
# Pre-build smoke test for Reader (roadmap item 1).
# Runs unit tests, a raw macOS 14 arm64 Debug xcodebuild, and an isolated
# launch of the built app against a throwaway PDF. Never touches SecondBrain,
# Arturo's Reader, or /Users/arturokuang/QA.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null; then
  echo "error: xcodegen is required to generate Reader.xcodeproj" >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null; then
  echo "error: xcodebuild is required" >&2
  exit 1
fi
if ! command -v swift >/dev/null; then
  echo "error: swift is required" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)-$$"
SCRATCH="$(mktemp -d "/tmp/reader-smoke-${STAMP}-XXXX")"
DERIVED="$SCRATCH/derived"
APP_PID=""
APP_LOG="$SCRATCH/app.log"

cleanup() {
  local status=$?
  if [[ -n "${APP_PID:-}" ]]; then
    if kill -0 "$APP_PID" 2>/dev/null; then
      local cmd
      cmd="$(ps -p "$APP_PID" -o command= 2>/dev/null || true)"
      # Only signal the process we launched (unique scratch path in argv).
      if [[ "$cmd" == *"$SCRATCH"* ]]; then
        kill "$APP_PID" 2>/dev/null || true
        local waited=0
        while kill -0 "$APP_PID" 2>/dev/null && [[ $waited -lt 20 ]]; do
          sleep 0.25
          waited=$((waited + 1))
        done
        if kill -0 "$APP_PID" 2>/dev/null; then
          kill -9 "$APP_PID" 2>/dev/null || true
        fi
      fi
    fi
    APP_PID=""
  fi
  rm -rf "$SCRATCH"
  return "$status"
}
trap cleanup EXIT

echo "==> 1. swift test (Packages/ReaderCore)"
swift test --package-path "$ROOT/Packages/ReaderCore"

if [[ -d "$ROOT/Packages/ReaderSync" ]]; then
  echo "==> 1b. swift test (Packages/ReaderSync)"
  swift test --package-path "$ROOT/Packages/ReaderSync"
fi

echo "==> 2. generate project + raw xcodebuild (macOS 14, Debug, arm64)"
xcodegen generate --spec "$ROOT/project.yml"

# Unique bundle ID so this launch cannot attach to a running Reader or QA instance.
BUNDLE_ID="com.reader.Reader.smoke.${STAMP}"
# Capture the real xcodebuild exit code. Never pipe through tail/tee.
set +e
xcodebuild \
  -project "$ROOT/Reader.xcodeproj" \
  -scheme Reader \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED" \
  MACOSX_DEPLOYMENT_TARGET=14.0 \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  build
XCODE_STATUS=$?
set -e
if [[ $XCODE_STATUS -ne 0 ]]; then
  echo "error: xcodebuild exited $XCODE_STATUS" >&2
  exit "$XCODE_STATUS"
fi
echo "xcodebuild exited 0"

APP="$DERIVED/Build/Products/Debug/Reader.app"
if [[ ! -x "$APP/Contents/MacOS/Reader" ]]; then
  echo "error: built app missing at $APP" >&2
  exit 1
fi

echo "==> 3. isolated launch of $BUNDLE_ID"
HOME_DIR="$SCRATCH/home"
PDF_DIR="$SCRATCH/docs"
LAUNCH_TMP="$SCRATCH/tmp"
mkdir -p "$HOME_DIR" "$PDF_DIR" "$LAUNCH_TMP"

# Minimal one-page PDF written only under this scratch directory.
python3 - "$PDF_DIR/Smoke.pdf" << 'PY'
import sys
path = sys.argv[1]
objects = [
    b"1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n",
    b"2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj\n",
    b"3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>endobj\n",
]
parts = [b"%PDF-1.4\n"]
offsets = [0]
pos = len(parts[0])
for obj in objects:
    offsets.append(pos)
    parts.append(obj)
    pos += len(obj)
xref_start = pos
xref = [f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()]
for off in offsets[1:]:
    xref.append(f"{off:010d} 00000 n \n".encode())
trailer = (
    f"trailer<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref_start}\n%%EOF\n"
).encode()
data = b"".join(parts + xref + [trailer])
with open(path, "wb") as handle:
    handle.write(data)
PY

# Copy the app into the scratch tree so the running binary is not the shared product.
LAUNCH_APP="$SCRATCH/ReaderSmoke.app"
cp -R "$APP" "$LAUNCH_APP"
# Keep the unique bundle ID on the copy (already baked in by xcodebuild).
BIN="$LAUNCH_APP/Contents/MacOS/Reader"

# Isolated HOME / TMPDIR: no SecondBrain, no Application Support of Arturo's Reader.
HOME="$HOME_DIR" \
TMPDIR="$LAUNCH_TMP" \
"$BIN" -ApplePersistenceIgnoreState YES "$PDF_DIR/Smoke.pdf" \
  >"$APP_LOG" 2>&1 &
APP_PID=$!
# Drop job-control so the later cleanup SIGTERM is not printed as "Terminated: 15".
disown "$APP_PID" 2>/dev/null || true

# Confirm we only ever track this scratch launch.
CMD="$(ps -p "$APP_PID" -o command= 2>/dev/null || true)"
if [[ "$CMD" != *"$SCRATCH"* ]]; then
  echo "error: launched PID $APP_PID does not look like the scratch Reader: $CMD" >&2
  exit 1
fi

# Stay alive cleanly for a few seconds (no crash), and open the temp PDF.
alive=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "error: Reader exited early; log:" >&2
    cat "$APP_LOG" >&2 || true
    wait "$APP_PID" || true
    exit 1
  fi
  sleep 0.5
  alive=1
done

if [[ $alive -ne 1 ]]; then
  echo "error: Reader did not stay running" >&2
  exit 1
fi

if grep -Eiq 'fatal error|EXC_|SIGABRT|SIGSEGV|Trace/BPT trap|does not exist|couldn.?t open|failed to open' "$APP_LOG"; then
  echo "error: isolated launch log reported a failure:" >&2
  cat "$APP_LOG" >&2
  exit 1
fi

# The process should still have the throwaway PDF open (or at least on its argv).
if ! ps -p "$APP_PID" -o command= | grep -q "$PDF_DIR/Smoke.pdf"; then
  echo "error: scratch Reader is no longer holding the temp PDF on its command line" >&2
  ps -p "$APP_PID" -o command= >&2 || true
  exit 1
fi

# Prefer lsof evidence when available, but argv is enough if lsof is delayed.
if command -v lsof >/dev/null; then
  if lsof -p "$APP_PID" 2>/dev/null | grep -q "$PDF_DIR/Smoke.pdf"; then
    echo "temp PDF is open in the scratch process"
  else
    echo "note: lsof did not list the temp PDF yet; argv still has it"
  fi
fi

echo "isolated Reader (PID $APP_PID, $BUNDLE_ID) launched and stayed alive"
# cleanup trap kills only this PID and removes $SCRATCH (including the PDF and HOME).
echo "smoke-test: pass"
