#!/usr/bin/env bash
# Build the Zig server (zig-out/bin/mlx-serve) with the deployment floor and the
# staged MLX kept in lockstep by ONE knob.
#
# The two knobs that must agree:
#   * MLX_DEPLOYMENT_TARGET (scripts/build-mlx.sh) — decides whether MLX's NAX
#     gate opens AND the Metal language version stamped into mlx.metallib. A
#     26.x target is language 4.0, which macOS 15 refuses to load (#230).
#   * -Dmin-os (build.zig) — the executable's LC_BUILD_VERSION minos. It goes
#     through default_target, not -Dtarget, so Zig's native CPU detection
#     (-mcpu) survives.
# A binary whose floor sits BELOW the staged metallib boots on an old Mac only
# to die on that metallib, so build.sh refuses that combination outright.
#
# Usage:
#   ./scripts/build.sh                      # Tahoe: mlx at 26.2 + NAX, binary minos 26.2
#   ./scripts/build.sh --sequoia            # macOS 15: mlx at 15.0 (no NAX), binary minos 15.0
#   ./scripts/build.sh --target=15.3        # any explicit floor
#   ./scripts/build.sh --skip-mlx           # re-link only (lib/mlx already staged)
#   ./scripts/build.sh --skip-deps          # ... and don't re-run fetch-llama/fetch-zig
#   ./scripts/build.sh --print-target       # just echo the resolved target
#   ./scripts/build.sh --check-only         # run the floor-vs-metallib gate and stop
#
# Always ReleaseFast: Debug decode is 2-4x slower and every latency read off it
# is fake. Guard test: tests/test_install_prefix.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

TARGET="${MLX_DEPLOYMENT_TARGET:-26.2}"
SKIP_MLX=0
SKIP_DEPS=0
PRINT_TARGET=0
CHECK_ONLY=0

die() { echo "[build] ERROR: $*" >&2; exit 1; }
note() { echo "[build] $*"; }

# ver_ge A B — dotted version comparison (15.0 >= 15.0, 26.2 >= 15.3).
ver_ge() {
  local am aj bm bj
  am=${1%%.*}; aj=$(echo "$1" | cut -d. -f2); aj=${aj:-0}
  bm=${2%%.*}; bj=$(echo "$2" | cut -d. -f2); bj=${bj:-0}
  [ "$am" -gt "$bm" ] || { [ "$am" -eq "$bm" ] && [ "$aj" -ge "$bj" ]; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target=*) TARGET="${1#*=}" ;;
    --target) [ $# -ge 2 ] || die "--target needs a value"; TARGET="$2"; shift ;;
    --sequoia) TARGET="15.0" ;;
    --skip-mlx) SKIP_MLX=1 ;;
    --skip-deps) SKIP_DEPS=1 ;;
    --print-target) PRINT_TARGET=1 ;;
    --check-only) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
  shift
done

# A floor is "26.2" or "15.0": digits plus one or two dots. build.zig parses it
# as a version, so anything else must be named here, not as a Zig panic.
case "$TARGET" in
  ''|*[!0-9.]*|.*|*.) die "--target '$TARGET' is not a version like 26.2, 15.0 or 15.3" ;;
esac
DOTS="${TARGET//[!.]/}"
case "${#DOTS}" in
  1|2) ;;
  *) die "--target '$TARGET' is not a version like 26.2, 15.0 or 15.3" ;;
esac

if [ "$PRINT_TARGET" = 1 ] && [ "$CHECK_ONLY" = 0 ]; then
  echo "$TARGET"
  exit 0
fi

# ── The gate: a binary floor below the staged metallib is the #230 death ─────
STAGED="$(sed -n 's/.*target=\([0-9.]*\).*/\1/p' lib/mlx/.version 2>/dev/null | head -1)"
STAGED="${STAGED:-26.2}"
if [ ! -f lib/mlx/lib/mlx.metallib ]; then
  note "lib/mlx not staged yet — floor-vs-metallib gate runs after build-mlx.sh"
elif ! ver_ge "$TARGET" "$STAGED"; then
  die "binary floor $TARGET is below the $STAGED that lib/mlx was staged at: lib/mlx/lib/mlx.metallib carries Metal language 4.0, which a pre-Tahoe runtime refuses. Rebuild MLX at the same target: MLX_DEPLOYMENT_TARGET=$TARGET ./scripts/build-mlx.sh"
elif ver_ge "$STAGED" "$TARGET"; then
  [ "$STAGED" = "$TARGET" ] || note "NOTE: staged lib/mlx is at $STAGED, above the $TARGET binary floor (fine here, not a Sequoia artifact)"
fi

if [ "$CHECK_ONLY" = 1 ]; then
  echo "$TARGET"
  note "gate ok: binary floor $TARGET vs staged lib/mlx $STAGED"
  exit 0
fi

export MLX_DEPLOYMENT_TARGET="$TARGET"

if [ "$SKIP_DEPS" = 0 ]; then
  [ -f lib/mlx-src/CMakeLists.txt ] && [ -f lib/mlxc-src/CMakeLists.txt ] \
    || die "submodules missing — run: git submodule update --init --recursive"
  ./scripts/fetch-llama.sh
fi

if [ "$SKIP_MLX" = 0 ]; then
  ./scripts/build-mlx.sh
else
  [ -f lib/mlx/lib/libmlx.dylib ] || die "--skip-mlx but lib/mlx/lib/libmlx.dylib is missing"
fi

if [ -x .zig-toolchain/zig ]; then
  ZIG="$REPO_ROOT/.zig-toolchain/zig"
elif [ "$SKIP_DEPS" = 0 ]; then
  ./scripts/fetch-zig.sh
  ZIG="$REPO_ROOT/.zig-toolchain/zig"
else
  ZIG="$(command -v zig || true)"
  [ -n "$ZIG" ] || die "no zig on PATH and no .zig-toolchain/zig (run ./scripts/fetch-zig.sh)"
fi

note "building ReleaseFast, min-os $TARGET with $("$ZIG" version)"
"$ZIG" build -Doptimize=ReleaseFast -Dmin-os="$TARGET"

BIN="zig-out/bin/mlx-serve"
MINOS="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
NAX="$(strings lib/mlx/lib/mlx.metallib | grep -c '_nax' || true)"
OS_NOW="$(sw_vers -productVersion)"

note "built $BIN (minos $MINOS), lib/mlx at $STAGED with $NAX NAX symbol hits"
"$BIN" --version
if ! ver_ge "$OS_NOW" "$MINOS"; then
  note "NOTE: this Mac is macOS $OS_NOW, below the binary's $MINOS floor — it runs here, do not hand this build to another Mac expecting it to boot"
fi
