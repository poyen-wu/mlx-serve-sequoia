#!/usr/bin/env bash
# The raw-BF16 n-gram table path across the language boundary:
# `tests/gguf_ple_to_ngram_table.py` turns a `*-PLEBF16-*` GGUF split into an
# `ngram_table.bin` by APFS-cloning the split and rewriting only its header (the
# 102 GB payload never moves), and `NgramTable.open` must accept exactly what
# that tool writes. The tool's own self-test builds a tiny GGUF with the real
# split's geometry (data start 192); this script hands that fixture to the Zig
# test that reads it with the engine's parser.
#
# Usage: bash tests/test_ngram_bf16_table.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
# The pinned nightly (`.zig-toolchain/zig`, see scripts/fetch-zig.sh); brew's zig
# is a different major and cannot build this tree.
ZIG="$(command -v zig)"
if [ -x "$ROOT/.zig-toolchain/zig" ]; then ZIG="$ROOT/.zig-toolchain/zig"; fi

python3 tests/gguf_ple_to_ngram_table.py --self-test --fixture-dir "$TMP" > "$TMP/tool.log" 2>&1
if [ $? -ne 0 ]; then
    echo "FAIL [1]: tool self-test"; cat "$TMP/tool.log"; exit 1
fi
echo "PASS [1]: $(tail -1 "$TMP/tool.log")"

# [2] The engine's parser reads the patched fixture: geometry, and every row's
# values off the payload formula the tool wrote. The binary is run DIRECTLY, not
# through `zig build test`: a Run step gets a clean environment, so an env-gated
# test SKIPS and the build still reports success. Requiring OK (never SKIP) is
# what makes this a check at all.
"$ZIG" build test-build -Dtest-filter="patched out of a GGUF clone" > "$TMP/zig.log" 2>&1 \
    || { echo "FAIL [2a]: zig build test-build"; tail -20 "$TMP/zig.log"; exit 1; }
run_fixture() {
    MLX_SERVE_NGRAM_BF16_FIXTURE="$1" "$ROOT/zig-out/tests/test" 2>&1
}
OUT="$(run_fixture "$TMP/ngram_table.bin")"
echo "$OUT" | grep -q "patched out of a GGUF clone\.\.\.OK" || { echo "FAIL [2b]:"; echo "$OUT" | tail -12; exit 1; }
echo "PASS [2]: NgramTable.open accepts the patched fixture"

# [3] Anti-false-green: name a fixture that does not exist and the test must
# FAIL, so a skipped run can never be reported as a pass.
if OUT="$(run_fixture "$TMP/no-such-file.bin")"; then
    echo "FAIL [3]: a missing fixture did not fail the test:"; echo "$OUT" | tail -6; exit 1
fi
echo "$OUT" | grep -q "SKIP" && { echo "FAIL [3]: skipped, not failed"; exit 1; }
echo "PASS [3]: the test really reads the fixture"

exit $fail
