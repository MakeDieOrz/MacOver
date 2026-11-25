#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DERIVED_DATA="${REPO_ROOT}/.build/playtools-analyze-dd"
DERIVED_DATA_EXPLICIT=0
CHECK_FORMAT=0
CLEAN_CACHE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data)
      DERIVED_DATA="${2:?--derived-data requires a path}"
      DERIVED_DATA_EXPLICIT=1
      shift 2
      ;;
    --check-format)
      CHECK_FORMAT=1
      shift
      ;;
    --clean)
      CLEAN_CACHE=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--derived-data <path>] [--check-format] [--clean]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "${CLEAN_CACHE}" -eq 1 ]]; then
  rm -rf "${DERIVED_DATA}"
fi
mkdir -p "${DERIVED_DATA}"

LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/playtools-analyze-log.XXXXXX")"
cleanup() {
  rm -f "${LOG_FILE}"
}
trap cleanup EXIT
: "${DERIVED_DATA_EXPLICIT}"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if [[ "${CHECK_FORMAT}" -eq 1 ]]; then
  echo "==> Validating .clang-format configuration..."
  xcrun clang-format --style="file:${REPO_ROOT}/.clang-format" --dump-config >/dev/null
  echo "==> Checking clang-format compliance on curated C/ObjC sources..."
  CURATED_FORMAT_FILES=(
    "${REPO_ROOT}/PlayTools/PlayTools/PTCallerAddressMath.h"
    "${REPO_ROOT}/PlayTools/PlayTools/PTCallerAddressMath.c"
    "${REPO_ROOT}/PlayTools/PlayTools/Subsystems/PTRegistration.h"
    "${REPO_ROOT}/PlayTools/PlayTools/Subsystems/PTRegistration.c"
    "${REPO_ROOT}/PlayTools/PlayTools/Subsystems/PTDebugTrace.h"
    "${REPO_ROOT}/PlayTools/PlayTools/Subsystems/PTDebugTrace.c"
    "${REPO_ROOT}/PlayTools/PlayTools/PlayLoader.h"
    "${REPO_ROOT}/PlayTools/PlayTools/PlayLoader.m"
  )
  for fmt_file in "${CURATED_FORMAT_FILES[@]}"; do
    xcrun clang-format --style="file:${REPO_ROOT}/.clang-format" --dry-run --Werror "${fmt_file}"
  done
  CLANG_TIDY_BIN="$(command -v clang-tidy || true)"
  if [[ -z "${CLANG_TIDY_BIN}" && -x "/opt/homebrew/opt/llvm/bin/clang-tidy" ]]; then
    CLANG_TIDY_BIN="/opt/homebrew/opt/llvm/bin/clang-tidy"
  fi
  if [[ -n "${CLANG_TIDY_BIN}" ]]; then
    echo "==> Validating .clang-tidy configuration..."
    "${CLANG_TIDY_BIN}" --config-file="${REPO_ROOT}/.clang-tidy" --dump-config >/dev/null
  else
    echo "==> Note: clang-tidy not installed locally; skipping .clang-tidy dump-config check."
  fi
fi

echo "==> Running Clang Static Analyzer on PlayTools (Mac Catalyst arm64)..."
xcodebuild \
  -project "${REPO_ROOT}/PlayTools/PlayTools.xcodeproj" \
  -scheme PlayTools \
  -configuration Debug \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "${DERIVED_DATA}" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CLANG_ANALYZER_OUTPUT=text \
  CLANG_ANALYZER_LOCALIZABILITY_NONLOCALIZED=NO \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  analyze 2>&1 | tee "${LOG_FILE}"

echo "==> Checking analyzer diagnostics for PlayTools sources..."
python3 - "${REPO_ROOT}" "${LOG_FILE}" <<'PY'
import re
import sys
from pathlib import Path

repo_root = str(Path(sys.argv[1]).resolve())
log_path = Path(sys.argv[2])
target_prefix = f"{repo_root}/PlayTools/"

findings = []
in_analyze = False
for raw_line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
    if raw_line.startswith("Analyze ") or raw_line.startswith("AnalyzeShallow "):
        in_analyze = True
    elif raw_line.startswith(("CompileC ", "SwiftCompile ", "Ld ", "PhaseScriptExecution ", "CopySwiftLibs ")):
        in_analyze = False
    if in_analyze and ": warning:" in raw_line and target_prefix in raw_line:
        # Exclude standard compiler flags like [-Wundeclared-selector]; retain static analyzer checker tags [checker.name].
        if "[-W" not in raw_line and re.search(r"\[[A-Za-z0-9_.]+]$", raw_line.strip()):
            findings.append(raw_line.strip())

print(f"Clang Static Analyzer findings count: {len(findings)}")
for item in findings:
    print("  " + item.replace(repo_root + "/", ""))

if findings:
    sys.exit(1)
PY
