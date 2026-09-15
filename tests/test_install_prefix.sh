#!/bin/bash
# test_install_prefix.sh — guards for scripts/build.sh + scripts/install.sh.
#
# scripts/install.sh turns zig-out/bin/mlx-serve into a relocatable install:
# the binary plus lib/{libmlx,libmlxc,libjaccl,libllama,mlx.metallib,webp},
# load commands rewired off @rpath/absolute-brew paths onto
# @executable_path/lib / @loader_path, then re-signed ad-hoc (install_name_tool
# invalidates the linker signature). Two failure classes it must never ship:
#
#   A leftover @rpath or absolute-Homebrew reference resolves on the BUILD
#   machine only — the install runs here and dies on another Mac with a dyld
#   "Library not loaded". The binary's deployment floor and the staged mlx
#   target may also disagree: a 15.x binary beside a 26.x metallib boots
#   nowhere ("language version 4.0 which is not supported on this OS", #230).
#   Re-running the installer must not double-rewrite or fail — the second pass
#   sees already-rewired load commands.
#
# Usage: ./tests/test_install_prefix.sh        (needs zig-out/bin/mlx-serve built)

set -u
cd "$(dirname "$0")/.." || exit 1

BIN="zig-out/bin/mlx-serve"
INSTALL="scripts/install.sh"
BUILD="scripts/build.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/msv-install-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

command -v install_name_tool >/dev/null 2>&1 || { echo "NOTE: install_name_tool missing (macOS only) — skipped"; exit 0; }
[ -x "$BUILD" ]   || { echo "FAIL: $BUILD missing or not executable"; exit 1; }
[ -x "$INSTALL" ] || { echo "FAIL: $INSTALL missing or not executable"; exit 1; }

echo "== build.sh resolves ONE target for both knobs =="
T_DEFAULT="$("$BUILD" --print-target 2>/dev/null)"
T_SEQUOIA="$("$BUILD" --print-target --sequoia 2>/dev/null)"
T_EXPLICIT="$("$BUILD" --print-target --target=15.3 2>/dev/null)"
[ "$T_DEFAULT" = "26.2" ] && ok "--print-target defaults to 26.2" \
  || fail "--print-target default is '$T_DEFAULT', want 26.2"
[ "$T_SEQUOIA" = "15.0" ] && ok "--sequoia resolves to 15.0" \
  || fail "--sequoia is '$T_SEQUOIA', want 15.0"
[ "$T_EXPLICIT" = "15.3" ] && ok "--target= passes through" \
  || fail "--target= is '$T_EXPLICIT', want 15.3"

echo "== build.sh refuses a binary floor below the staged mlx target =="
STAGED="$(sed -n 's/.*target=\([0-9.]*\).*/\1/p' lib/mlx/.version 2>/dev/null | head -1)"
STAGED="${STAGED:-26.2}"
LOWER="$(awk -F. -v v="$STAGED" 'BEGIN{print v+0-1".0"}')"
OUT="$("$BUILD" --print-target --target="$LOWER" --skip-mlx --check-only 2>&1)"; RC=$?
if [ $RC -ne 0 ] && echo "$OUT" | grep -qi "metallib"; then
  ok "--target=$LOWER under a staged $STAGED mlx refused, naming the metallib"
else
  fail "--target=$LOWER under a staged $STAGED mlx was accepted (rc=$RC): a 15.x binary beside a 26.x metallib boots nowhere: $OUT"
fi

[ -f "$BIN" ] || { echo "NOTE: $BIN not built — install checks skipped (zig build -Doptimize=ReleaseFast)"; printf '%s\n' "== $PASS passed, $FAIL failed =="; [ $FAIL -eq 0 ] && exit 0 || exit 1; }

WEBP_LIB="$(brew --prefix webp 2>/dev/null)/lib"
[ -d "$WEBP_LIB" ] || WEBP_LIB=""

PREFIX="$WORK/opt/mlx-serve"
LINK="$WORK/.local/bin/mlx-serve"
mkdir -p "$(dirname "$LINK")"

echo "== --dry-run plans the install and writes nothing =="
OUT="$("$INSTALL" --prefix "$PREFIX" --link "$LINK" --dry-run 2>&1)"; RC=$?
[ $RC -eq 0 ] && ok "--dry-run exits 0" || fail "--dry-run exited $RC: $OUT"
[ ! -e "$PREFIX" ] && ok "--dry-run created no prefix" || fail "--dry-run wrote into $PREFIX"
for want in "copy $BIN" "change @rpath/libmlxc.dylib" "change @rpath/libllama.dylib" \
            "change @rpath/libmlx.dylib" "add-rpath" "sign" "link"; do
  echo "$OUT" | grep -q "$want" && ok "plan names: $want" || fail "plan omits: $want"
done

echo "== install into a temp prefix =="
OUT="$("$INSTALL" --prefix "$PREFIX" --link "$LINK" 2>&1)"; RC=$?
[ $RC -eq 0 ] && ok "install exits 0" || { fail "install exited $RC"; echo "$OUT" | sed 's/^/      /'; }
for f in mlx-serve lib/libmlx.dylib lib/libmlxc.dylib lib/libllama.dylib lib/mlx.metallib; do
  [ -f "$PREFIX/$f" ] && ok "installed $f" || fail "missing $f"
done
[ -f "$PREFIX/NOTICE" ] && ok "installed NOTICE (Apache-2.0 ports ride the binary)" \
  || fail "NOTICE missing — section 4 of Apache-2.0 wants it to reach the receiver"
[ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$PREFIX/mlx-serve" ] \
  && ok "link points at the installed binary" || fail "$LINK is not a link to $PREFIX/mlx-serve"

# The whole point: no reference survives that only resolves on this machine.
RPATH="$(otool -L "$PREFIX/mlx-serve" | grep -c '@rpath/' || true)"
[ "$RPATH" = "0" ] && ok "binary keeps no @rpath reference" \
  || fail "binary still has $RPATH @rpath reference(s): $(otool -L "$PREFIX/mlx-serve" | grep '@rpath/' | tr '\n' ' ')"
ABS="$(otool -L "$PREFIX/mlx-serve" | awk 'NR>1{print $1}' | grep '^/' | grep -v -E '^/(System|usr/lib)' | grep -v ':$' || true)"
[ -z "$ABS" ] && ok "binary links no absolute non-system path (no Homebrew-only dep)" \
  || fail "binary links an absolute Homebrew path: $ABS"
otool -L "$PREFIX/lib/libmlxc.dylib" | grep -q '@loader_path/libmlx.dylib' \
  && ok "libmlxc resolves libmlx inside lib/" || fail "libmlxc still references @rpath/libmlx.dylib"
otool -L "$PREFIX/mlx-serve" | grep -q '@executable_path/lib/libmlxc.dylib' \
  && ok "binary resolves libmlxc under lib/" || fail "binary does not reference @executable_path/lib/libmlxc.dylib"
codesign --verify "$PREFIX/mlx-serve" 2>/dev/null \
  && ok "ad-hoc signature valid after the rewrite" || fail "codesign --verify failed on the rewired binary"
codesign -dv "$PREFIX/mlx-serve" 2>&1 | grep -q 'adhoc' \
  && ok "signature is ad-hoc (no Developer ID needed locally)" || fail "installed binary is not ad-hoc signed"
OUT="$("$PREFIX/mlx-serve" --version 2>&1)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qE '^mlx-serve [0-9]' && ok "installed binary runs from its own prefix" \
  || { fail "installed binary did not run (rc=$RC): $OUT"; }

echo "== re-running is not a second rewrite =="
# A dylib nothing links is a decoy: it looks like a bundled dependency while the
# binary actually resolves that dependency somewhere else (the bug an existing
# install ships: lib/libwebp.dylib copied, /opt/homebrew path still referenced).
cp "$PREFIX/lib/libllama.dylib" "$PREFIX/lib/libdecoy.dylib"
OUT="$("$INSTALL" --prefix "$PREFIX" --link "$LINK" 2>&1)"; RC=$?
[ $RC -eq 0 ] && ok "second install exits 0" || { fail "second install exited $RC"; echo "$OUT" | sed 's/^/      /'; }
echo "$OUT" | grep -q "libdecoy.dylib" && ok "second install names the unreferenced dylib" \
  || fail "second install said nothing about libdecoy.dylib"
[ ! -e "$PREFIX/lib/libdecoy.dylib" ] && ok "unreferenced dylib removed" || fail "libdecoy.dylib survived: a dylib nothing links is a decoy"
cp "$PREFIX/lib/libllama.dylib" "$PREFIX/lib/libdecoy.dylib"
OUT="$("$INSTALL" --prefix "$PREFIX" --link "$LINK" --keep-unreferenced 2>&1)"; RC=$?
[ $RC -eq 0 ] && [ -f "$PREFIX/lib/libdecoy.dylib" ] && ok "--keep-unreferenced keeps it" \
  || fail "--keep-unreferenced (rc=$RC) did not keep libdecoy.dylib"
RPATH="$(otool -L "$PREFIX/mlx-serve" | grep -c '@rpath/' || true)"
[ "$RPATH" = "0" ] && ok "still no @rpath after a second pass" || fail "second pass left @rpath references"
codesign --verify "$PREFIX/mlx-serve" 2>/dev/null \
  && ok "still signed after a second pass" || fail "second pass broke the signature"
OUT="$("$PREFIX/mlx-serve" --version 2>&1)"
echo "$OUT" | grep -qE '^mlx-serve [0-9]' && ok "still runs after a second pass" || fail "second pass broke the binary: $OUT"
for f in libmlx.dylib libmlxc.dylib libllama.dylib; do
  [ -f "$PREFIX/lib/$f" ] && ok "prune kept the referenced $f" \
    || fail "prune deleted $f, which the binary links — the install cannot start"
done

echo "== a webp we cannot bundle is refused by name =="
if [ -n "$WEBP_LIB" ]; then
  EMPTY="$WORK/no-webp"; mkdir -p "$EMPTY"
  OUT="$("$INSTALL" --prefix "$WORK/opt2" --no-link --webp-lib "$EMPTY" 2>&1)"; RC=$?
  if [ $RC -ne 0 ] && echo "$OUT" | grep -q "webp"; then
    ok "missing libwebp refuses the install, naming webp"
  else
    fail "missing libwebp was accepted (rc=$RC): the install would link a Homebrew-only path: $OUT"
  fi
  OUT="$("$INSTALL" --prefix "$WORK/opt2" --no-link --webp-lib "$EMPTY" --allow-system-webp 2>&1)"; RC=$?
  [ $RC -eq 0 ] && ok "--allow-system-webp overrides the refusal" || fail "--allow-system-webp refused (rc=$RC): $OUT"
  [ -x "$WORK/opt2/mlx-serve" ] && ok "override still installs" || fail "override installed nothing"
else
  echo "  NOTE: brew webp missing — refusal checks skipped"
fi

echo "== --no-sign says it skipped signing =="
OUT="$("$INSTALL" --prefix "$WORK/opt3" --no-link --no-sign 2>&1)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qi "skip" \
  && ok "--no-sign reports that signing was skipped" \
  || fail "--no-sign (rc=$RC) never said it skipped signing: $OUT"

printf '%s\n' "== $PASS passed, $FAIL failed =="
[ $FAIL -eq 0 ] || exit 1
