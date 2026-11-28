#!/usr/bin/env bash
# G3 Anti-Cheat & Manifest Integrity Guard for Reader formal verification.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MANIFEST="$ROOT/formal/manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
  echo "FAIL: missing formal/manifest.json" >&2
  exit 1
fi

python3 - "$ROOT" "$MANIFEST" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

errors = []

for key in ("repo", "sync_commit", "tla2tools_sha256", "models", "code_harnesses"):
    if key not in manifest or not manifest[key]:
        errors.append(f"manifest missing required key: {key}")

if not re.fullmatch(r"[0-9a-f]{40}", str(manifest.get("sync_commit", ""))):
    errors.append(f"manifest sync_commit must be a 40-char SHA, got: {manifest.get('sync_commit')!r}")

if not re.fullmatch(r"[0-9a-f]{64}", str(manifest.get("tla2tools_sha256", ""))):
    errors.append("manifest tla2tools_sha256 must be a 64-char SHA-256 hex digest")

models = manifest.get("models", [])
if len(models) < 3:
    errors.append(f"expected at least 3 TLA+ models in manifest, found {len(models)}")

for model in models:
    name = model.get("name", "<unnamed>")
    for field in ("spec", "config", "deep_config", "canary_config"):
        rel = model.get(field)
        if not rel or not (root / rel).is_file():
            errors.append(f"model {name}: missing {field} file {rel!r}")
    for rel in model.get("covered_files", []):
        if not (root / rel).exists():
            errors.append(f"model {name}: covered_file does not exist: {rel!r}")
    if not model.get("canary_expected_invariant"):
        errors.append(f"model {name}: missing canary_expected_invariant")

    for cfg_field, expect_bug in (("config", False), ("deep_config", False), ("canary_config", True)):
        rel = model.get(cfg_field)
        if not rel or not (root / rel).is_file():
            continue
        text = (root / rel).read_text(encoding="utf-8")
        if not re.search(r"^\s*INVARIANT\b|^\s*INVARIANTS\b", text, re.M):
            errors.append(f"model {name} ({rel}): declares no INVARIANT")
        m = re.search(r'^\s*BUG_MODE\s*=\s*"([^"]+)"', text, re.M)
        if not m:
            errors.append(f"model {name} ({rel}): missing BUG_MODE constant assignment")
        else:
            val = m.group(1)
            if not expect_bug and val != "none":
                errors.append(f"model {name} ({rel}): non-canary config must have BUG_MODE = \"none\", got {val!r}")
            if expect_bug and val == "none":
                errors.append(f"model {name} ({rel}): canary config must inject a bug (BUG_MODE != \"none\")")

forbidden_swift = [
    (re.compile(r"\bXCTSkip\b"), "XCTSkip is forbidden in formal verification harnesses"),
    (re.compile(r"\bXCTExpectFailure\b"), "XCTExpectFailure is forbidden in formal verification harnesses"),
    (re.compile(r"\bexit\s*\(\s*0\s*\)"), "early exit(0) is forbidden in formal harnesses"),
]
forbidden_ts = [
    (re.compile(r"\b(?:test|it|describe)\.skip\b"), ".skip is forbidden in formal verification harnesses"),
    (re.compile(r"\b(?:test|it|describe)\.only\b"), ".only is forbidden in formal verification harnesses"),
    (re.compile(r"process\.exit\s*\(\s*0\s*\)"), "early process.exit(0) is forbidden in formal harnesses"),
]

code_harnesses = manifest.get("code_harnesses", [])
if not code_harnesses:
    errors.append("manifest lists no code_harnesses")

for entry in code_harnesses:
    rel = entry if isinstance(entry, str) else entry.get("path") or entry.get("file")
    if not rel or not (root / rel).is_file():
        errors.append(f"code harness missing on disk: {rel!r}")
        continue
    src = (root / rel).read_text(encoding="utf-8")
    if rel.endswith(".swift"):
        if "func test" not in src:
            errors.append(f"Swift formal harness {rel} contains no XCTest methods")
        for pattern, reason in forbidden_swift:
            for match in pattern.finditer(src):
                line = src.count("\n", 0, match.start()) + 1
                errors.append(f"{rel}:{line}: {reason}")
    elif rel.endswith(".ts"):
        if "test(" not in src and "it(" not in src:
            errors.append(f"TypeScript formal harness {rel} contains no test cases")
        for pattern, reason in forbidden_ts:
            for match in pattern.finditer(src):
                line = src.count("\n", 0, match.start()) + 1
                errors.append(f"{rel}:{line}: {reason}")
    if isinstance(entry, dict):
        for cov in entry.get("covered_files", []):
            if not (root / cov).exists():
                errors.append(f"code harness {rel}: covered_file does not exist: {cov!r}")

skill_path = root / ".cursor/skills/formal-verify-reader/SKILL.md"
if not skill_path.is_file():
    errors.append("missing project-local skill .cursor/skills/formal-verify-reader/SKILL.md")
else:
    skill_text = skill_path.read_text(encoding="utf-8")
    if not skill_text.startswith("---\n") or "name: formal-verify-reader" not in skill_text[:400]:
        errors.append("formal-verify-reader/SKILL.md missing valid YAML frontmatter")

if errors:
    print("G3 anti-cheat / manifest guard FAILED:", file=sys.stderr)
    for err in errors:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)

print(f"G3 anti-cheat / manifest guard PASSED ({len(models)} TLA+ models, {len(code_harnesses)} code harnesses verified).")
PY
