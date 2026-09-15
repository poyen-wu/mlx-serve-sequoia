#!/bin/bash
# test_mlx_staged_nax.sh — static guard for the self-built, NAX-enabled MLX runtime.
#
# mlx-serve pins mlx + mlx-c as git submodules and builds them via
# scripts/build-mlx.sh with CMAKE_OSX_DEPLOYMENT_TARGET=26.2 so MLX's NAX
# (M5 neural-accelerator) kernels are compiled in — the Homebrew bottle is
# built at deployment target 26.0 and silently ships with MLX_METAL_NO_NAX
# (is_nax_available() hard-wired false, even on M5 hardware).
#
# Verifies, without running any GPU code:
#   1. the staged runtime exists: lib/mlx/lib/{libmlx.dylib,libmlxc.dylib,mlx.metallib}
#   2. the metallib's NAX kernels match the deployment target the stage was
#      built at — present at 26.2+, absent below it (the CMake gate fails
#      SILENTLY, so a wrong target is otherwise invisible)
#   3. libmlx.dylib's minos (LC_BUILD_VERSION) is >= that same target, proving
#      the deployment target took effect
#   4. libmlxc.dylib links the staged libmlx, not /opt/homebrew's bottle
#   5. the .version stamp exists (build-mlx.sh provenance)
#   6. if zig-out/bin/mlx-serve is built: it links no Homebrew mlx/mlx-c
#
# Usage: ./tests/test_mlx_staged_nax.sh

set -u
cd "$(dirname "$0")/.." || exit 1

STAGE="lib/mlx"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# ver_ge A B — dotted version comparison (15.0 >= 15.0, 26.2 >= 26.2).
ver_ge() {
  local am aj bm bj
  am=${1%%.*}; aj=$(echo "$1" | cut -d. -f2); aj=${aj:-0}
  bm=${2%%.*}; bj=$(echo "$2" | cut -d. -f2); bj=${bj:-0}
  [ "$am" -gt "$bm" ] || { [ "$am" -eq "$bm" ] && [ "$aj" -ge "$bj" ]; }
}

# The deployment target the stage was built at, stamped by scripts/build-mlx.sh.
# 26.2 is the default and is what unlocks MLX's NAX gate; anything lower is a
# deliberate pre-Tahoe build (macOS 15 "Sequoia", issue #230), where NAX cannot
# be compiled at all and a 26.x metallib carries Metal language version 4.0 that
# the older runtime refuses. So the checks below follow the stamp instead of
# assuming Tahoe.
STAMP_TARGET="$(sed -n 's/.*target=\([0-9.]*\).*/\1/p' "$STAGE/.version" 2>/dev/null | head -1)"
STAMP_TARGET="${STAMP_TARGET:-26.2}"
if ver_ge "$STAMP_TARGET" 26.2; then WANT_NAX=1; else WANT_NAX=0; fi
echo "== staged deployment target $STAMP_TARGET (NAX expected: $WANT_NAX) =="

echo "== staged files =="
for f in "$STAGE/lib/libmlx.dylib" "$STAGE/lib/libmlxc.dylib" "$STAGE/lib/mlx.metallib"; do
  if [ -f "$f" ]; then ok "$f exists"; else fail "$f missing (run scripts/build-mlx.sh)"; fi
done
if [ -f "$STAGE/.version" ]; then
  ok ".version stamp present ($(tr '\n' ' ' < "$STAGE/.version"))"
else
  fail "$STAGE/.version missing (run scripts/build-mlx.sh)"
fi

echo "== NAX kernels match the deployment target =="
if [ -f "$STAGE/lib/mlx.metallib" ]; then
  NAX_COUNT=$(strings "$STAGE/lib/mlx.metallib" | grep -c "_nax" || true)
  if [ "$WANT_NAX" = 1 ] && [ "$NAX_COUNT" -gt 0 ]; then
    ok "metallib contains NAX kernels ($NAX_COUNT symbol hits)"
  elif [ "$WANT_NAX" = 1 ]; then
    fail "metallib has ZERO *_nax kernels at target $STAMP_TARGET — the 26.2 CMake gate failed silently (wrong SDK/deployment target or missing Metal Toolchain)"
  elif [ "$NAX_COUNT" = 0 ]; then
    ok "no NAX kernels, correct for deployment target $STAMP_TARGET (pre-Tahoe build)"
  else
    fail "metallib carries $NAX_COUNT *_nax symbol hits at deployment target $STAMP_TARGET — the NAX gate did not respect the target"
  fi
else
  fail "cannot check NAX kernels: metallib missing"
fi

echo "== libmlx minos >= staged deployment target =="
if [ -f "$STAGE/lib/libmlx.dylib" ]; then
  MINOS=$(otool -l "$STAGE/lib/libmlx.dylib" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')
  if [ -n "$MINOS" ] && ver_ge "$MINOS" "$STAMP_TARGET"; then
    ok "libmlx.dylib minos is $MINOS"
  else
    fail "libmlx.dylib minos is '$MINOS' — need >= $STAMP_TARGET to match the deployment target it was staged at"
  fi
else
  fail "cannot check minos: libmlx.dylib missing"
fi

echo "== mlx-c links the staged mlx, not Homebrew =="
if [ -f "$STAGE/lib/libmlxc.dylib" ]; then
  if otool -L "$STAGE/lib/libmlxc.dylib" | grep -q "/opt/homebrew"; then
    fail "libmlxc.dylib still references /opt/homebrew:"$'\n'"$(otool -L "$STAGE/lib/libmlxc.dylib" | grep /opt/homebrew)"
  else
    ok "libmlxc.dylib has no /opt/homebrew references"
  fi
else
  fail "cannot check linkage: libmlxc.dylib missing"
fi

echo "== mlx-serve binary linkage + min-OS (if built) =="
BIN="zig-out/bin/mlx-serve"
if [ -f "$BIN" ]; then
  if otool -L "$BIN" | grep -Eq "/opt/homebrew/(opt|Cellar)/(mlx|mlx-c)/"; then
    fail "mlx-serve still links Homebrew mlx/mlx-c:"$'\n'"$(otool -L "$BIN" | grep -E '/opt/homebrew/(opt|Cellar)/(mlx|mlx-c)/')"
  else
    ok "mlx-serve links no Homebrew mlx/mlx-c"
  fi
  # The binary's own minos must state the honest floor — the same one the libmlx
  # it links was staged at. Too high and dyld refuses to launch it; too low and
  # it "loads" on old macOS only to die on the dylib with a worse error.
  BIN_MINOS=$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')
  if [ -n "$BIN_MINOS" ] && ver_ge "$BIN_MINOS" "$STAMP_TARGET"; then
    ok "mlx-serve minos is $BIN_MINOS"
  else
    fail "mlx-serve minos is '$BIN_MINOS' — must match the libmlx floor ($STAMP_TARGET; build.zig -Dmin-os)"
  fi
else
  echo "  NOTE: $BIN not built — linkage + minos checks skipped (build with: zig build -Doptimize=ReleaseFast)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
