#!/usr/bin/env bash
#
# mayhem/build.sh — build the POCO fuzz harnesses (upstream's own, from <Component>/fuzzing/), their
# standalone reproducers, and the CppUnit test runners that mayhem/test.sh executes.
# Re-runnable (incremental cmake/ninja trees) and offline (no fetches; OpenSSL/zlib come from the image).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# cmake target (upstream) -> shipped binary (OSS-Fuzz name, also the Mayhemfile target)
FUZZERS=(
  "JSON-parse-fuzzer:json_parser_fuzzer"
  "XML-parse-fuzzer:xml_parser_fuzzer"
  "Foundation-datetime-fuzzer:date_time_fuzzer"
  "Foundation-misc-fuzzer:foundation_misc_fuzzer"
  "JWT-decode-fuzzer:jwt_decode_fuzzer"
  "Net-mail-parser-fuzzer:mail_message_fuzzer"
  "Net-http-parser-fuzzer:http_message_fuzzer"
  "AIMCP-server-fuzzer:mcp_server_fuzzer"
  "AIMCP-client-fuzzer:mcp_client_fuzzer"
  "AIMCPHTTP-eventstream-fuzzer:mcp_event_stream_fuzzer"
)
TESTRUNNERS=(JSON-testrunner XML-testrunner JWT-testrunner AIMCP-testrunner)

# Build directories are named cmake-build-* so upstream's .gitignore covers them (git clean -ffdX).
FUZZ_DIR="$SRC/cmake-build-fuzz"
STANDALONE_DIR="$SRC/cmake-build-standalone"
TEST_DIR="$SRC/cmake-build-tests"

COMMON_ARGS=(
  # CC/CXX come from the environment (by name); passing -DCMAKE_C_COMPILER=clang on a re-run would differ from the
  # cached absolute path and make cmake wipe the cache. RelWithDebInfo (not Release): poco links Release with -s.
  -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_SHARED_LIBS=OFF
  "-DCMAKE_C_FLAGS_RELWITHDEBINFO=-O2 -DNDEBUG" "-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-O2 -DNDEBUG"
  -DENABLE_ACTIVERECORD=OFF -DENABLE_ACTIVERECORD_COMPILER=OFF
  -DENABLE_PAGECOMPILER=OFF -DENABLE_PAGECOMPILER_FILE2PAGE=OFF
  -DENABLE_DATA=OFF -DENABLE_DATA_SQLITE=OFF -DENABLE_DATA_ODBC=OFF -DENABLE_DATA_MYSQL=OFF -DENABLE_DATA_POSTGRESQL=OFF
  -DENABLE_REDIS=OFF -DENABLE_MONGODB=OFF -DENABLE_PROMETHEUS=OFF -DENABLE_NETSSL=OFF
  -DENABLE_AI_MCP=ON -DENABLE_AI_MCP_HTTP=ON -DENABLE_JWT=ON -DENABLE_CRYPTO=ON
)

# 0) LeakSanitizer off at build time (leaks are not the bug class we fuzz for), linked into every fuzz binary.
mkdir -p "$FUZZ_DIR" "$STANDALONE_DIR"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_DIR/lsan_off.o"
cp "$FUZZ_DIR/lsan_off.o" "$STANDALONE_DIR/lsan_off.o"
# The run-once driver is C: compile it as C so LLVMFuzzerTestOneInput keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$STANDALONE_DIR/standalone_main.o"

fuzz_targets=(); for f in "${FUZZERS[@]}"; do fuzz_targets+=("${f%%:*}"); done

# 1) Sanitized libFuzzer build. The project is compiled with sanitizers + sancov (fuzzer-no-link) so the
#    fuzzed library code is instrumented, not just the harness; the harness links the engine through
#    upstream's LINK_FLAGS $ENV{LIB_FUZZING_ENGINE}.
LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" cmake -S "$SRC" -B "$FUZZ_DIR" "${COMMON_ARGS[@]}" \
  -DENABLE_FUZZING=ON -DENABLE_TESTS=OFF \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $FUZZ_DIR/lsan_off.o"
cmake --build "$FUZZ_DIR" -j"$MAYHEM_JOBS" --target "${fuzz_targets[@]}"

# 2) Standalone (non-fuzzer) reproducers: same harnesses linked against the run-once driver, no sancov/libFuzzer runtime.
LIB_FUZZING_ENGINE="$STANDALONE_DIR/standalone_main.o" cmake -S "$SRC" -B "$STANDALONE_DIR" "${COMMON_ARGS[@]}" \
  -DENABLE_FUZZING=ON -DENABLE_TESTS=OFF \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $STANDALONE_DIR/lsan_off.o"
cmake --build "$STANDALONE_DIR" -j"$MAYHEM_JOBS" --target "${fuzz_targets[@]}"

for f in "${FUZZERS[@]}"; do
  cp -f "$FUZZ_DIR/bin/${f%%:*}" "$SRC/${f##*:}"
  cp -f "$STANDALONE_DIR/bin/${f%%:*}" "$SRC/${f##*:}-standalone"
done

# 3) The project's own CppUnit suites with NORMAL flags (no sanitizers) — mayhem/test.sh only runs them.
cmake -S "$SRC" -B "$TEST_DIR" "${COMMON_ARGS[@]}" \
  -DENABLE_TESTS=ON -DENABLE_FUZZING=OFF \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST_DIR" -j"$MAYHEM_JOBS" --target "${TESTRUNNERS[@]}"
