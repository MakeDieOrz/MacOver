#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

OUT_DIR="${REPO_ROOT}/.build/unit-tests-c"
mkdir -p "${OUT_DIR}"
BIN_PATH="${OUT_DIR}/test_compat104_fixes"

echo "==> Compiling pure-C unit tests with ASan + UBSan..."
xcrun clang \
  -std=gnu23 \
  -Wall -Wextra -Werror \
  -g -O1 \
  -fsanitize=address,undefined \
  -fno-omit-frame-pointer \
  -I"${REPO_ROOT}/PlayTools/PlayTools" \
  -I"${REPO_ROOT}/PlayTools/PlayTools/Subsystems" \
  "${REPO_ROOT}/Tests/UnitTests/test_compat104_fixes.c" \
  "${REPO_ROOT}/PlayTools/PlayTools/PTCallerAddressMath.c" \
  "${REPO_ROOT}/PlayTools/PlayTools/Subsystems/PTDebugTrace.c" \
  "${REPO_ROOT}/PlayTools/PlayTools/Subsystems/PTRegistration.c" \
  "${REPO_ROOT}/PlayTools/PlayTools/Subsystems/PTInterposeRegistry.c" \
  "${REPO_ROOT}/PlayTools/PlayTools/Subsystems/PTCodeSignParser.c" \
  "${REPO_ROOT}/PlayTools/PlayTools/Subsystems/PTArm64StubMath.c" \
  "${REPO_ROOT}/PlayTools/PlayTools/Subsystems/PTDetectionRules.c" \
  -o "${BIN_PATH}"

echo "==> Running ${BIN_PATH}..."
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
  "${BIN_PATH}"
