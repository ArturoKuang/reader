#!/usr/bin/env bash
# Code Quality & Architectural Fitness Ratchet Gate for Reader.
# Enforces hard package boundaries (ReaderCore/ReaderSync free of AppKit/PDFKit/WebKit,
# ReaderSync never writes Obsidian conflict callouts) and prevents regression of Swift
# force-unwraps/try!/fatalError, TypeScript any/@ts-ignore, and monolithic file growth.
# Usage:
#   ./Scripts/code-quality.sh           # verify against .ci/quality-ratchet.json
#   ./Scripts/code-quality.sh --update  # recompute ratchet ceilings
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UPDATE=0
if [[ "${1:-}" == "--update" ]]; then
  UPDATE=1
fi

python3 - "$ROOT" "$UPDATE" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
update = sys.argv[2] == "1"
ratchet_path = root / ".ci/quality-ratchet.json"

def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return src

boundary_errors = []

# Boundary 1: Packages/ReaderCore must stay platform-neutral (no AppKit, PDFKit, WebKit, ReaderSync).
for sf in sorted((root / "Packages/ReaderCore/Sources").glob("**/*.swift")):
    clean = strip_comments(sf.read_text(encoding="utf-8"))
    for mod in ("AppKit", "PDFKit", "WebKit", "SwiftUI", "ReaderSync"):
        if re.search(rf"^\s*import\s+{mod}\b", clean, re.M):
            boundary_errors.append(f"boundary violation: {sf.relative_to(root)} imports {mod}")

# Boundary 2: Packages/ReaderSync must stay headless (no AppKit, PDFKit, WebKit, SwiftUI)
# and never emit legacy Obsidian conflict callout text (SYNC_SPEC §0 / D7).
for sf in sorted((root / "Packages/ReaderSync/Sources").glob("**/*.swift")):
    raw = sf.read_text(encoding="utf-8")
    clean = strip_comments(raw)
    for mod in ("AppKit", "PDFKit", "WebKit", "SwiftUI"):
        if re.search(rf"^\s*import\s+{mod}\b", clean, re.M):
            boundary_errors.append(f"boundary violation: {sf.relative_to(root)} imports {mod}")
    if "Also changed outside Reader" in raw:
        boundary_errors.append(f"SYNC_SPEC D7 violation: {sf.relative_to(root)} contains legacy conflict callout string")

# Collect production Swift & mobile TypeScript quality metrics.
swift_prod_files = sorted(
    list((root / "Packages/ReaderCore/Sources").glob("**/*.swift"))
    + list((root / "Packages/ReaderSync/Sources").glob("**/*.swift"))
    + list((root / "App/Reader").glob("**/*.swift"))
)

metrics = {
    "swift_prod_try_bang": 0,
    "swift_prod_fatal_or_precondition_fail": 0,
    "swift_prod_force_cast": 0,
    "swift_prod_files_over_600_loc": 0,
    "swift_prod_max_file_loc": 0,
    "mobile_ts_prod_any_or_ignore": 0,
    "mobile_ts_prod_files_over_600_loc": 0,
}

for sf in swift_prod_files:
    raw = sf.read_text(encoding="utf-8")
    clean = strip_comments(raw)
    loc = len(raw.splitlines())
    metrics["swift_prod_max_file_loc"] = max(metrics["swift_prod_max_file_loc"], loc)
    if loc > 600:
        metrics["swift_prod_files_over_600_loc"] += 1
    metrics["swift_prod_try_bang"] += len(re.findall(r"\btry!", clean))
    metrics["swift_prod_fatal_or_precondition_fail"] += len(
        re.findall(r"\b(?:fatalError|preconditionFailure)\s*\(", clean)
    )
    metrics["swift_prod_force_cast"] += len(re.findall(r"\bas!\s+[A-Za-z_]", clean))

mobile_src = root / "apps/mobile/src"
if mobile_src.is_dir():
    for tf in sorted(list(mobile_src.glob("**/*.ts")) + list(mobile_src.glob("**/*.tsx"))):
        rel = str(tf.relative_to(root))
        if ".test." in tf.name or ".jest." in tf.name or "/formal/" in rel or "/mock/" in rel:
            continue
        raw = tf.read_text(encoding="utf-8")
        if len(raw.splitlines()) > 600:
            metrics["mobile_ts_prod_files_over_600_loc"] += 1
        metrics["mobile_ts_prod_any_or_ignore"] += len(
            re.findall(r":\s*any\b|\bas\s+any\b|@ts-ignore|@ts-expect-error|eslint-disable", raw)
        )

if update:
    ratchet_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "description": "Code quality ceilings for Reader. Values may tighten over time but CI blocks regressions.",
        "ceilings": metrics,
    }
    ratchet_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"Updated {ratchet_path.relative_to(root)}: {json.dumps(metrics)}")
    sys.exit(0)

if not ratchet_path.is_file():
    print(f"FAIL: missing {ratchet_path.relative_to(root)} (run with --update to initialize)", file=sys.stderr)
    sys.exit(1)

ceilings = json.loads(ratchet_path.read_text(encoding="utf-8"))["ceilings"]
ratchet_errors = []
improvements = []
for key, ceiling in ceilings.items():
    actual = metrics.get(key, 0)
    if actual > ceiling:
        ratchet_errors.append(f"{key}: actual={actual} exceeds ceiling={ceiling}")
    elif actual < ceiling:
        improvements.append(f"{key}: improved {ceiling} -> {actual} (tighten with ./Scripts/code-quality.sh --update)")

if boundary_errors or ratchet_errors:
    print("Code quality & architectural fitness gate FAILED:", file=sys.stderr)
    for err in boundary_errors + ratchet_errors:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)

print("  [PASS] architectural boundaries (ReaderCore/ReaderSync headless, no legacy vault conflict callouts)")
print(f"  [PASS] quality ratchet ceilings ({', '.join(f'{k}={v}/{ceilings[k]}' for k, v in metrics.items())})")
for imp in improvements:
    print(f"  [TIP]  {imp}")
PY
