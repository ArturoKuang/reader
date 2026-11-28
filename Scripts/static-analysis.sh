#!/usr/bin/env bash
# G0 Static Analysis Gate for Reader.
# Runs Swift package builds, mobile TypeScript typecheck & eslint, shellcheck,
# actionlint, gitleaks secret scanning, conflict-marker checks, and code-quality ratchets.
# Usage:
#   ./Scripts/static-analysis.sh           # full repo check (CI / pre-push)
#   ./Scripts/static-analysis.sh --staged  # fast staged-only check (pre-commit)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STAGED_ONLY=0
if [[ "${1:-}" == "--staged" ]]; then
  STAGED_ONLY=1
fi

FAILURES=0
step_ok() { printf '  [PASS] %s\n' "$1"; }
step_warn() { printf '  [WARN] %s\n' "$1"; }
step_fail() { printf '  [FAIL] %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

echo "==> G0: Static analysis (mode=$([ "$STAGED_ONLY" -eq 1 ] && echo staged || echo full))"

STAGED_FILES=()
if [[ "$STAGED_ONLY" -eq 1 ]]; then
  while IFS= read -r file; do
    [[ -n "$file" ]] && STAGED_FILES+=("$file")
  done < <(git diff --cached --name-only --diff-filter=ACMR)
  if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
    echo "No staged files; skipping static analysis."
    exit 0
  fi
fi

has_staged_match() {
  local pattern="$1"
  local f
  for f in "${STAGED_FILES[@]}"; do
    if [[ "$f" =~ $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# 1. Merge conflict markers
if [[ "$STAGED_ONLY" -eq 1 ]]; then
  if git diff --cached --check >/dev/null 2>&1; then
    step_ok "git diff --cached --check (whitespace & conflict markers)"
  else
    git diff --cached --check >&2 || true
    step_fail "git diff --cached --check reported conflict markers or bad whitespace"
  fi
else
  if git grep -nE '^(<<<<<<< |=======$|>>>>>>> )' -- ':!*package-lock.json' >/dev/null 2>&1; then
    git grep -nE '^(<<<<<<< |=======$|>>>>>>> )' -- ':!*package-lock.json' >&2 || true
    step_fail "merge conflict markers found in repository"
  else
    step_ok "no merge conflict markers"
  fi
fi

# 2. Secret scanning (gitleaks)
if command -v gitleaks >/dev/null 2>&1; then
  if [[ "$STAGED_ONLY" -eq 1 ]]; then
    if gitleaks protect --staged --no-banner --redact >/dev/null 2>&1; then
      step_ok "gitleaks (staged secrets scan)"
    else
      gitleaks protect --staged --no-banner --redact >&2 || true
      step_fail "gitleaks detected a potential secret in staged changes"
    fi
  else
    if gitleaks detect --no-git --source "$ROOT" --no-banner --redact >/dev/null 2>&1; then
      step_ok "gitleaks (working tree secrets scan)"
    else
      gitleaks detect --no-git --source "$ROOT" --no-banner --redact >&2 || true
      step_fail "gitleaks detected a potential secret in repository"
    fi
  fi
else
  if [[ "${CI:-}" == "true" ]]; then
    step_fail "gitleaks is required in CI but not found on PATH"
  else
    step_warn "gitleaks not installed locally; skipping secret scan (install: brew install gitleaks)"
  fi
fi

# 3. Shell script syntax & shellcheck
SHELL_TARGETS=()
if [[ "$STAGED_ONLY" -eq 1 ]]; then
  for f in "${STAGED_FILES[@]}"; do
    if [[ "$f" == *.sh || "$f" == .githooks/* ]]; then
      [[ -f "$f" ]] && SHELL_TARGETS+=("$f")
    fi
  done
else
  for f in Scripts/*.sh .githooks/*; do
    [[ -f "$f" ]] && SHELL_TARGETS+=("$f")
  done
fi

if [[ ${#SHELL_TARGETS[@]} -gt 0 ]]; then
  SYNTAX_OK=1
  for f in "${SHELL_TARGETS[@]}"; do
    if ! bash -n "$f"; then
      SYNTAX_OK=0
    fi
  done
  if [[ "$SYNTAX_OK" -eq 1 ]]; then
    step_ok "bash -n syntax check (${#SHELL_TARGETS[@]} scripts)"
  else
    step_fail "bash -n syntax errors found"
  fi

  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning "${SHELL_TARGETS[@]}"; then
      step_ok "shellcheck -S warning (${#SHELL_TARGETS[@]} scripts)"
    else
      step_fail "shellcheck reported warnings/errors"
    fi
  elif [[ "${CI:-}" == "true" ]]; then
    step_fail "shellcheck is required in CI but not found on PATH"
  else
    step_warn "shellcheck not installed locally; skipping (install: brew install shellcheck)"
  fi
fi

# 4. GitHub Actions workflow linting (actionlint)
RUN_ACTIONLINT=0
if [[ "$STAGED_ONLY" -eq 0 ]] || has_staged_match '^\.github/'; then
  RUN_ACTIONLINT=1
fi
if [[ "$RUN_ACTIONLINT" -eq 1 ]] && compgen -G ".github/workflows/*.yml" >/dev/null; then
  if command -v actionlint >/dev/null 2>&1; then
    if actionlint .github/workflows/*.yml; then
      step_ok "actionlint (.github/workflows/*.yml)"
    else
      step_fail "actionlint reported workflow errors"
    fi
  elif [[ "${CI:-}" == "true" ]]; then
    step_fail "actionlint is required in CI but not found on PATH"
  else
    step_warn "actionlint not installed locally; skipping (install: brew install actionlint)"
  fi
fi

# 5. Swift static build check on ReaderCore & ReaderSync
RUN_SWIFT=0
if [[ "$STAGED_ONLY" -eq 0 ]] || has_staged_match '\.swift$|Package\.swift$'; then
  RUN_SWIFT=1
fi
if [[ "$RUN_SWIFT" -eq 1 ]]; then
  if swift build --package-path "$ROOT/Packages/ReaderCore" --build-tests >/dev/null; then
    step_ok "swift build (Packages/ReaderCore + tests)"
  else
    step_fail "swift build failed for Packages/ReaderCore"
  fi
  if swift build --package-path "$ROOT/Packages/ReaderSync" --build-tests >/dev/null; then
    step_ok "swift build (Packages/ReaderSync + tests)"
  else
    step_fail "swift build failed for Packages/ReaderSync"
  fi
fi

# 6. Mobile TypeScript typecheck & eslint
RUN_MOBILE=0
if [[ "$STAGED_ONLY" -eq 0 ]] || has_staged_match '^apps/mobile/'; then
  RUN_MOBILE=1
fi
if [[ "$RUN_MOBILE" -eq 1 && -f "apps/mobile/package.json" ]]; then
  if [[ -d "apps/mobile/node_modules" ]]; then
    if (cd apps/mobile && npm run typecheck); then
      step_ok "apps/mobile TypeScript typecheck (tsc --noEmit)"
    else
      step_fail "apps/mobile TypeScript typecheck failed"
    fi
    if (cd apps/mobile && npm run lint); then
      step_ok "apps/mobile eslint (expo lint)"
    else
      step_fail "apps/mobile eslint failed"
    fi
  elif [[ "${CI:-}" == "true" ]]; then
    step_fail "apps/mobile/node_modules missing in CI"
  else
    step_warn "apps/mobile/node_modules not present locally; skipping mobile tsc/eslint"
  fi
fi

# 7. Code quality & architectural fitness ratchet
if [[ -x "$ROOT/Scripts/code-quality.sh" ]]; then
  if "$ROOT/Scripts/code-quality.sh"; then
    step_ok "code-quality architectural fitness & ratchet"
  else
    step_fail "code-quality architectural fitness & ratchet failed"
  fi
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "G0 static analysis FAILED with $FAILURES error(s)." >&2
  exit 1
fi
echo "G0 static analysis PASSED."
