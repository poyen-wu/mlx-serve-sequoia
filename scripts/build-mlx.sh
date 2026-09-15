#!/usr/bin/env bash
# Build the pinned mlx + mlx-c submodules (lib/mlx-src, lib/mlxc-src) into
# lib/mlx/{lib,include} with MLX's NAX (M5 neural-accelerator) kernels ENABLED.
#
# Why not Homebrew: the brew bottle is compiled at MACOSX_DEPLOYMENT_TARGET
# 26.0 (the Tahoe builders' point release), which fails MLX's CMake gate
# (SDK >= 26.2 AND deployment target >= 26.2) — the NAX kernels are silently
# skipped and MLX_METAL_NO_NAX hard-wires is_nax_available() to false, even on
# M5 hardware. Building ourselves at 26.2 flips the gate; the runtime check in
# MLX still gates dispatch on GPU gen >= 17, so M1–M4 behavior is unchanged.
#
# The gate fails SILENTLY upstream (a configure-time warning only landed after
# v0.32.0), so this script ASSERTS the result: no *_nax kernels in the built
# metallib = hard failure, never a quietly-degraded stage.
#
# Consequence of the 26.2 deployment target: the staged dylibs (and anything
# bundling them) require macOS >= 26.2 at runtime. MLX_DEPLOYMENT_TARGET=15.x
# builds for macOS 15 "Sequoia" instead (issue #230): no NAX, and a metallib at
# a Metal language version the pre-Tahoe runtime can actually load — a 26.x
# metallib is language version 4.0, which Sequoia refuses outright. The NAX and
# minos assertions below then follow the target rather than assuming Tahoe.
#
# This is the single source of truth for the pinned mlx/mlx-c versions: the
# submodule SHAs. Bump by checking out a new tag in the submodule; CI and
# local builds rebuild automatically (stamp mismatch). Guard test:
# tests/test_mlx_staged_nax.sh.
set -euo pipefail

DEPLOYMENT_TARGET="${MLX_DEPLOYMENT_TARGET:-26.2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MLX_SRC="$REPO_ROOT/lib/mlx-src"
MLXC_SRC="$REPO_ROOT/lib/mlxc-src"
STAGE="$REPO_ROOT/lib/mlx"
BUILD_ROOT="$REPO_ROOT/lib/.mlx-build"
STAMP="$STAGE/.version"

die() { echo "[build-mlx] ERROR: $*" >&2; exit 1; }

[ -f "$MLX_SRC/CMakeLists.txt" ] && [ -f "$MLXC_SRC/CMakeLists.txt" ] \
  || die "submodules missing — run: git submodule update --init lib/mlx-src lib/mlxc-src"

MLX_SHA="$(git -C "$MLX_SRC" rev-parse --short=12 HEAD)"
MLXC_SHA="$(git -C "$MLXC_SRC" rev-parse --short=12 HEAD)"
WANT="mlx=$MLX_SHA mlxc=$MLXC_SHA target=$DEPLOYMENT_TARGET"

# Idempotent: skip when the staged build already matches the pinned SHAs.
if [ -f "$STAMP" ] && [ -f "$STAGE/lib/libmlx.dylib" ] \
   && [ -f "$STAGE/lib/libmlxc.dylib" ] && [ -f "$STAGE/lib/mlx.metallib" ]; then
  if [ "$(cat "$STAMP")" = "$WANT" ]; then
    echo "[build-mlx] lib/mlx already at ($WANT) — nothing to do"
    exit 0
  fi
  echo "[build-mlx] staged '$(cat "$STAMP")' != '$WANT' — rebuilding"
fi

# ── Toolchain preflight: every one of these failing would otherwise surface
# as a silently NAX-less metallib, not an error. ──────────────────────────────
xcrun -sdk macosx metal --version >/dev/null 2>&1 \
  || die "Metal compiler unavailable — Xcode 26 ships it as a separate download: xcodebuild -downloadComponent MetalToolchain"

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
SDK_MINOR="$(echo "$SDK_VERSION" | cut -d. -f2)"
if [ "$SDK_MAJOR" -lt 26 ] || { [ "$SDK_MAJOR" -eq 26 ] && [ "${SDK_MINOR:-0}" -lt 2 ]; }; then
  die "macOS SDK $SDK_VERSION < 26.2 — MLX's NAX kernel gate needs SDK >= 26.2 (update Xcode)"
fi
echo "[build-mlx] SDK $SDK_VERSION, deployment target $DEPLOYMENT_TARGET, $WANT"

NCPU="$(sysctl -n hw.ncpu)"

# ── mlx (C++ core + metallib) ────────────────────────────────────────────────
cmake -S "$MLX_SRC" -B "$BUILD_ROOT/mlx" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DBUILD_SHARED_LIBS=ON \
  -DMLX_BUILD_TESTS=OFF \
  -DMLX_BUILD_EXAMPLES=OFF \
  -DCMAKE_INSTALL_PREFIX="$STAGE"
cmake --build "$BUILD_ROOT/mlx" -j "$NCPU"
cmake --install "$BUILD_ROOT/mlx" >/dev/null

# ── mlx-c against the staged mlx (same pairing brew uses: USE_SYSTEM_MLX) ────
cmake -S "$MLXC_SRC" -B "$BUILD_ROOT/mlxc" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DBUILD_SHARED_LIBS=ON \
  -DMLX_C_USE_SYSTEM_MLX=ON \
  -DMLX_C_BUILD_EXAMPLES=OFF \
  -DCMAKE_PREFIX_PATH="$STAGE" \
  -DCMAKE_INSTALL_PREFIX="$STAGE"
cmake --build "$BUILD_ROOT/mlxc" -j "$NCPU"
cmake --install "$BUILD_ROOT/mlxc" >/dev/null

# ── Assert the point of the exercise ─────────────────────────────────────────
METALLIB="$STAGE/lib/mlx.metallib"
[ -f "$METALLIB" ] || die "mlx.metallib not at $METALLIB — mlx changed its install layout"

NAX_COUNT="$(strings "$METALLIB" | grep -c "_nax" || true)"

MINOS="$(otool -l "$STAGE/lib/libmlx.dylib" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"

# ver_ge A B — dotted version compare; needed before the assertions below.
ver_ge() {
  local am aj bm bj
  am=${1%%.*}; aj=$(echo "$1" | cut -d. -f2); aj=${aj:-0}
  bm=${2%%.*}; bj=$(echo "$2" | cut -d. -f2); bj=${bj:-0}
  [ "$am" -gt "$bm" ] || { [ "$am" -eq "$bm" ] && [ "$aj" -ge "$bj" ]; }
}

# Sequoia (and any pre-Tahoe) build: MLX_DEPLOYMENT_TARGET < 26.2. NAX kernels
# cannot be compiled below 26.2, and a metallib built at a 26.x deployment
# target carries Metal language version 4.0, which the macOS 15 Metal runtime
# refuses to load ("language version 4.0 which is not supported on this OS").
# So an old-OS build must have NAX OFF and minos at its own target — the
# assertions follow the target instead of assuming Tahoe. MLX defines
# MLX_METAL_NO_NAX here, which pins is_nax_available() to false: correct on
# M1–M4 (NAX is M5-only) and the only option before Tahoe.
NAX_EXPECT="${MLX_NAX_EXPECT:-auto}"
if [ "$NAX_EXPECT" = auto ]; then
  if ver_ge "$DEPLOYMENT_TARGET" 26.2; then
    NAX_EXPECT=required
  else
    NAX_EXPECT=forbidden
  fi
fi

case "$NAX_EXPECT:$NAX_COUNT" in
  required:0)
    die "built metallib contains ZERO *_nax kernels — the 26.2 gate failed silently (check SDK/deployment target/Metal Toolchain)" ;;
  forbidden:0) ;;
  forbidden:*)
    die "metallib carries $NAX_COUNT *_nax symbol hits at deployment target $DEPLOYMENT_TARGET — the 26.2 NAX gate did not respect the target" ;;
  *) ;;
esac

[ -n "$MINOS" ] || die "no LC_BUILD_VERSION minos on libmlx.dylib"
# minos must come back at the target we asked for — a silently ignored
# CMAKE_OSX_DEPLOYMENT_TARGET is exactly the failure that produces a
# language-4.0 metallib on a build meant for an older OS.
ver_ge "$MINOS" "$DEPLOYMENT_TARGET" \
  || die "libmlx.dylib minos '$MINOS' < deployment target '$DEPLOYMENT_TARGET' — deployment target did not take"

[ -f "$STAGE/lib/libmlxc.dylib" ] || die "libmlxc.dylib missing from stage"

echo "$WANT" > "$STAMP"
echo "[build-mlx] staged lib/mlx OK: NAX expected=$NAX_EXPECT ($NAX_COUNT symbol hits), minos $MINOS"
