#!/bin/bash
# check.sh: one command that runs the checks for a change and prints a short verdict.
#
#   Scripts/check.sh            auto: pick checks from files changed vs origin/main
#   Scripts/check.sh all        every check, including the app build
#   Scripts/check.sh core sync  only the named checks
#
# Checks:
#   core    swift test, Packages/ReaderCore                    (~15 s)
#   sync    swift test, Packages/ReaderSync (live test skipped) (~20 s)
#   mobile  typecheck, tests, and lint in apps/mobile           (~10 s)
#   spec    sync spec schemas, fixtures, OpenAPI, and codegen   (~1 s)
#   app     xcodegen + Debug xcodebuild of Reader.app           (~40 s clean; first run fetches FluidAudio)
#
# Full logs go to $READER_CHECK_LOG_DIR (default $TMPDIR/reader-check). Only failures print.
# Exit status is non-zero if any check failed, or if a check you named could not run.
# Works with macOS's bash 3.2.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
LOG_DIR="${READER_CHECK_LOG_DIR:-$TMP_ROOT/reader-check}"
SPEC_PY="${READER_SPEC_PYTHON:-python3}"
mkdir -p "$LOG_DIR"

ALL="core sync mobile spec app"
SELECTED=""
EXPLICIT=0
RESULTS=""
FAILED=0
SKIPPED=0

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

add() {
  for t in "$@"; do
    case " $SELECTED " in *" $t "*) ;; *) SELECTED="$SELECTED $t" ;; esac
  done
}

# Map changed paths to checks. Keep in sync with the "Checks" table in AGENTS.md.
auto_select() {
  local base files
  base="$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null || true)"
  if [ -z "$base" ]; then
    echo "auto: no origin/main to diff against; running every check except app"
    add core sync mobile spec
    return
  fi
  files="$( { git -C "$ROOT" diff --name-only "$base"; git -C "$ROOT" ls-files --others --exclude-standard; } | sort -u)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      *.md) ;;
      Packages/ReaderCore/*) add core sync app ;;
      Packages/ReaderSync/*) add sync app ;;
      Packages/ReaderKokoro/*|App/*|project.yml) add app ;;
      apps/mobile/*) add mobile ;;
      docs/sync-design/*) add spec ;;
      spec/*) add core mobile ;;
    esac
  done <<EOF
$files
EOF
  if [ -z "$SELECTED" ]; then
    echo "auto: nothing to check for these changes (docs, scripts, or CI only)."
    echo "      Run 'Scripts/check.sh all' to run every check anyway."
    exit 0
  fi
  echo "auto: changes since $(git -C "$ROOT" rev-parse --short "$base") select:$SELECTED"
}

record() { RESULTS="$RESULTS$(printf '%-7s %-5s %s' "$1" "$2" "$3")"$'\n'; }

# A missing tool fails a check you named, and skips one that auto or all picked.
missing() {
  local name="$1" why="$2"
  if [ "$EXPLICIT" = 1 ]; then
    record "$name" FAIL "cannot run: $why"; FAILED=$((FAILED + 1))
  else
    record "$name" SKIP "not verified: $why"; SKIPPED=$((SKIPPED + 1))
  fi
}

# SwiftPM starts its own sandbox-exec and saves through a system temp folder; tsx listens on a
# socket. A sandboxed agent shell blocks all three, and the errors do not say so plainly.
blocked_by_sandbox() {
  grep -Eq 'sandbox_apply: Operation not permitted|permission to save the file|listen EPERM|syscall: .listen' "$1"
}

# Short, deduplicated, line-truncated excerpt so a failure does not flood the terminal.
excerpt() {
  grep -E '(error|failed|FAIL|✖|✕|●)[: ]' "$1" | grep -v '^\[' | sed "s#$ROOT/##g" | cut -c1-300 \
    | awk '!seen[$0]++' | head -20
  echo "   -- last lines:"
  tail -12 "$1" | sed "s#$ROOT/##g" | cut -c1-300
}

run() {
  local name="$1"; shift
  local log="$LOG_DIR/$name.log" start status secs
  echo "==> $name"
  start=$(date +%s)
  ( "$@" ) >"$log" 2>&1
  status=$?
  secs=$(( $(date +%s) - start ))
  if [ $status -eq 0 ]; then
    record "$name" PASS "${secs}s"
    return
  fi
  FAILED=$((FAILED + 1))
  if blocked_by_sandbox "$log"; then
    record "$name" FAIL "blocked by a sandbox, not a code failure. Rerun outside it. log: $log"
    echo "-- $name could not run: the shell's sandbox blocked the toolchain (see $log)."
    echo "   SwiftPM, xcodebuild, and tsx must run outside an agent sandbox. Rerun with it off."
    return
  fi
  record "$name" FAIL "${secs}s, log: $log"
  echo "-- $name failed (exit $status). Error lines, then the end of $log:"
  excerpt "$log"
}

check_core() { swift test --package-path "$ROOT/Packages/ReaderCore"; }
check_sync() { swift test --package-path "$ROOT/Packages/ReaderSync"; }

check_mobile() {
  local m="$ROOT/apps/mobile"
  npm --prefix "$m" run typecheck && npm --prefix "$m" test && npm --prefix "$m" run lint
}

check_spec() {
  local tools="$ROOT/docs/sync-design/tools" regen
  "$SPEC_PY" -I "$tools/validate.py" "$ROOT/docs/sync-design/spec" || return 1
  # The committed schemas must be exactly what make_schemas.py writes.
  regen="$(mktemp -d "$TMP_ROOT/reader-schemas.XXXXXX")"
  "$SPEC_PY" -I "$tools/make_schemas.py" "$regen" >/dev/null || return 1
  if ! diff -r "$regen" "$ROOT/docs/sync-design/spec/schemas"; then
    echo "error: spec/schemas differ from make_schemas.py output. Edit make_schemas.py, then run it."
    rm -rf "$regen"; return 1
  fi
  rm -rf "$regen"
  echo "schemas match make_schemas.py"
}

check_app() {
  xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" --quiet || return 1
  xcodebuild -project "$ROOT/Reader.xcodeproj" -scheme Reader -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/build" \
    CODE_SIGN_IDENTITY=- build
}

run_target() {
  case "$1" in
    core|sync)
      command -v swift >/dev/null || { missing "$1" "swift not found"; return; }
      run "$1" "check_$1" ;;
    mobile)
      command -v npm >/dev/null || { missing mobile "npm not found"; return; }
      [ -d "$ROOT/apps/mobile/node_modules" ] || { missing mobile "run: npm ci --prefix apps/mobile"; return; }
      run mobile check_mobile ;;
    spec)
      "$SPEC_PY" -c 'import jsonschema, referencing, openapi_spec_validator, yaml' 2>/dev/null || {
        missing spec "needs jsonschema referencing openapi-spec-validator pyyaml (pip install, or set READER_SPEC_PYTHON)"; return; }
      run spec check_spec ;;
    app)
      command -v xcodegen >/dev/null || { missing app "run: brew install xcodegen"; return; }
      command -v xcodebuild >/dev/null || { missing app "xcodebuild not found (install Xcode)"; return; }
      run app check_app ;;
  esac
}

if [ $# -eq 0 ]; then set -- auto; fi
for arg in "$@"; do
  case "$arg" in
    -h|--help|help) usage; exit 0 ;;
    auto) auto_select ;;
    all) add $ALL ;;
    core|sync|mobile|spec|app) EXPLICIT=1; add "$arg" ;;
    *) echo "unknown check: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# Run in a fixed order so the cheap checks report first.
for t in $ALL; do
  case " $SELECTED " in *" $t "*) run_target "$t" ;; esac
done

echo
echo "== summary (logs in $LOG_DIR)"
printf '%s' "$RESULTS"
if [ $FAILED -gt 0 ]; then
  echo "check: FAIL ($FAILED failed, $SKIPPED skipped)"
  exit 1
fi
if [ $SKIPPED -gt 0 ]; then
  echo "check: pass, but $SKIPPED skipped and NOT verified (see above)"
else
  echo "check: pass"
fi
