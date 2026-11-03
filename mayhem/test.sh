#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the CppUnit suites that mayhem/build.sh built (normal flags, no sanitizers). Each runner prints
# "OK (N tests)" on success or "Runs: N   Failures: F   Errors: E" on failure; a runner that prints
# neither (crashed / neutered) counts as one failed test, so a no-op program cannot pass.
BIN="$SRC/cmake-build-tests/bin"
IGNORE="$SRC/cppignore.lnx"
declare -A DIRS=(
  [JSON]="$SRC/cmake-build-tests/JSON/testsuite"
  [XML]="$SRC/cmake-build-tests/XML/testsuite"
  [JWT]="$SRC/cmake-build-tests/JWT/testsuite"
  [AIMCP]="$SRC/cmake-build-tests/AI/MCP/testsuite"
)
passed=0; failed=0
for suite in JSON XML JWT AIMCP; do
  runner="$BIN/$suite-testrunner"
  if [ ! -x "$runner" ] || [ ! -d "${DIRS[$suite]}" ]; then
    echo "test.sh: missing $runner (mayhem/build.sh must build it)" >&2
    failed=$((failed + 1)); continue
  fi
  out="$(cd "${DIRS[$suite]}" && timeout 900 "$runner" -ignore "$IGNORE" -all 2>&1)"; rc=$?
  printf '%s\n' "$out" | tail -n 15
  if [ "$rc" -eq 0 ] && [[ "$out" =~ OK\ \(([0-9]+)\ tests\) ]]; then
    passed=$((passed + BASH_REMATCH[1]))
  elif [[ "$out" =~ Runs:\ ([0-9]+)[[:space:]]+Failures:\ ([0-9]+)[[:space:]]+Errors:\ ([0-9]+) ]]; then
    f=$((BASH_REMATCH[2] + BASH_REMATCH[3]))
    failed=$((failed + f)); passed=$((passed + BASH_REMATCH[1] - f))
  else
    echo "test.sh: $suite-testrunner produced no result (rc=$rc)" >&2
    failed=$((failed + 1))
  fi
done

emit_ctrf "cppunit" "$passed" "$failed" 0
