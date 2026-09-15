#!/usr/bin/env bash
# Install zig-out/bin/mlx-serve as a relocatable, self-contained prefix:
#
#   <prefix>/mlx-serve            + LICENSE, LICENSE-APACHE-2.0, NOTICE
#   <prefix>/lib/                 libmlx, libmlxc, libjaccl, mlx.metallib,
#                                 libllama, and the webp dylibs the binary links
#
# and rewire its load commands so nothing resolves on the build machine only:
#
#   @rpath/libmlxc.dylib   -> @executable_path/lib/…   (mlx-serve)
#   <brew absolute path>   -> @executable_path/lib/…   (mlx-serve)
#   @rpath/libmlx.dylib    -> @loader_path/…           (libmlxc)
#   @rpath/libsharpyuv.dylib -> @loader_path/…         (libwebp)
#
# A leftover @rpath or /opt/homebrew path works here and dyld-fails everywhere
# else, so the install fails if one survives. install_name_tool rewrites load
# commands and invalidates the linker's ad-hoc signature, so every dylib is
# re-signed ad-hoc (codesign --sign -) and the binary last — release.yml does the
# same with a Developer ID + --options runtime; a local install must not copy
# that flag. mlx.metallib is copied beside libmlx.dylib because MLX loads it from
# there: without it the server dies at once ("Failed to load the default
# metallib"), which is also the #230 Sequoia symptom.
#
# Usage:
#   ./scripts/install.sh                          # -> ~/opt/mlx-serve, link ~/.local/bin/mlx-serve
#   ./scripts/install.sh --prefix DIR [--link PATH|--no-link]
#   ./scripts/install.sh --dry-run                # print the plan, write nothing
#   ./scripts/install.sh --no-sign                # rewrite only (unsigned: local experiments)
#   ./scripts/install.sh --bin --stage --llama --webp-lib PATH   # non-default sources
#   ./scripts/install.sh --allow-system-webp      # ship the Homebrew webp reference
#   ./scripts/install.sh --keep-unreferenced      # keep dylibs nothing links (default: remove)
#
# Guard test: tests/test_install_prefix.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PREFIX="$HOME/opt/mlx-serve"
BIN="zig-out/bin/mlx-serve"
MLX_STAGE="lib/mlx"
LLAMA_DIR="lib/llama/lib"
WEBP_DIR=""
LINK="$HOME/.local/bin/mlx-serve"
DO_LINK=1
DO_SIGN=1
DRY_RUN=0
ALLOW_SYSTEM_WEBP=0
PRUNE=1

die() { echo "[install] ERROR: $*" >&2; exit 1; }
note() { echo "[install] $*"; }
plan() { echo "[install] plan: $*"; }

# run CMD... — execute, or just print it under --dry-run.
run() {
  if [ "$DRY_RUN" = 1 ]; then plan "$*"; else "$@"; fi
}

# dep_pairs FILE — "REF<TAB>SRC" for every dependency that resolves outside the
# operating system: an absolute Homebrew path, or an @rpath name that lives next
# to FILE. otool -L repeats FILE's own install name on line 2, and prints a
# "path:" header on line 1 — neither is a dependency, and shipping one as a
# dependency rewrites a dylib to point at itself.
dep_pairs() {
  local file="$1" self dir ref name
  self="$(otool -D "$file" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  dir="$(dirname "$file")"
  otool -L "$file" | awk 'NR>1{print $1}' | grep -v ':$' | while read -r ref; do
    case "$ref" in
      /System/*|/usr/lib/*|@executable_path/*|@loader_path/*) continue ;;
      @rpath/*)
        name="${ref#@rpath/}"
        [ "$name" = "${self##*/}" ] && continue
        [ -f "$dir/$name" ] && printf '%s\t%s\n' "$ref" "$dir/$name"
        ;;
      /*)
        [ "$ref" = "$self" ] && continue
        if [ -f "$dir/$(basename "$ref")" ]; then printf '%s\t%s\n' "$ref" "$dir/$(basename "$ref")"
        elif [ -f "$ref" ]; then printf '%s\t%s\n' "$ref" "$ref"; fi
        ;;
    esac
  done
}

# rewrite REL INSPECT OLD NEW — install_name_tool on $PREFIX/REL, planned from
# INSPECT (the source file) under --dry-run. Tolerant of a source whose load
# commands were already rewired, e.g. a --bin pointing at an old install.
rewrite() {
  local rel="$1" inspect="$2" old="$3" new="$4"
  [ -f "$inspect" ] || die "$rel references neither $old nor $new — unexpected linkage, refusing to guess"
  if otool -L "$inspect" | grep -qF "$old"; then
    plan "change $old -> $new in $rel"
    [ "$DRY_RUN" = 1 ] || install_name_tool -change "$old" "$new" "$PREFIX/$rel"
  elif otool -L "$inspect" | grep -qF "$new"; then
    note "load command already rewired: $rel -> $new"
  else
    die "$rel references neither $old nor $new — unexpected linkage, refusing to guess"
  fi
}

# bundle_src REF SRC — where to copy a third-party dylib from; --webp-lib makes
# it a hard requirement, so naming a directory without it is a refusal rather
# than a silent install that stays tied to this Mac's Homebrew path.
bundle_src() {
  local ref="$1" src="$2" base
  [ -z "$WEBP_DIR" ] && { printf '%s\n' "$src"; return 0; }
  base="$WEBP_DIR/$(basename "$src")"
  if [ -f "$base" ]; then printf '%s\n' "$base"; return 0; fi
  [ "$ALLOW_SYSTEM_WEBP" = 1 ] && { printf '%s\n' ""; return 0; }
  die "cannot bundle $(basename "$src") (looked in $WEBP_DIR) but mlx-serve links $ref: the install would resolve only on a Mac with that same Homebrew path. brew install webp, point --webp-lib at a directory holding it, or pass --allow-system-webp."
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; PREFIX="${2%/}"; shift ;;
    --bin) [ $# -ge 2 ] || die "--bin needs a value"; BIN="$2"; shift ;;
    --stage) [ $# -ge 2 ] || die "--stage needs a value"; MLX_STAGE="${2%/}"; shift ;;
    --llama) [ $# -ge 2 ] || die "--llama needs a value"; LLAMA_DIR="${2%/}"; shift ;;
    --webp-lib) [ $# -ge 2 ] || die "--webp-lib needs a value"; WEBP_DIR="${2%/}"; shift ;;
    --link) [ $# -ge 2 ] || die "--link needs a value"; LINK="$2"; shift ;;
    --no-link) DO_LINK=0 ;;
    --no-sign) DO_SIGN=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --allow-system-webp) ALLOW_SYSTEM_WEBP=1 ;;
    --keep-unreferenced) PRUNE=0 ;;
    -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
  shift
done

[ -f "$BIN" ] || die "$BIN missing — build it first: ./scripts/build.sh"
[ -f "$MLX_STAGE/lib/libmlx.dylib" ] || die "$MLX_STAGE/lib/libmlx.dylib missing — run ./scripts/build-mlx.sh"
[ -f "$MLX_STAGE/lib/mlx.metallib" ] || die "$MLX_STAGE/lib/mlx.metallib missing — without it the server dies at startup, so refusing"
case "$PREFIX" in ''|/) die "--prefix must be a real directory (refusing '$PREFIX')" ;; esac

LIBDIR="$PREFIX/lib"
[ "$DRY_RUN" = 1 ] || mkdir -p "$LIBDIR"

# A server running from this prefix keeps its old bytes; writing an executable
# in place is ETXTBSY, so the binary always lands via .tmp + mv.
RUNNING="$(pgrep -f "$PREFIX/mlx-serve" || true)"
[ -n "$RUNNING" ] && note "a server installed here is running (pid ${RUNNING// /, }) — restart it to pick up the new binary"

if [ "$DRY_RUN" = 1 ]; then
  plan "copy $BIN -> $PREFIX/mlx-serve"
  plan "copy $MLX_STAGE/lib/*.dylib + mlx.metallib -> $LIBDIR/"
  [ -d "$LLAMA_DIR" ] && plan "copy $LLAMA_DIR/libllama.dylib -> $LIBDIR/libllama.dylib"
else
  cp "$BIN" "$PREFIX/mlx-serve.tmp"
  for f in LICENSE LICENSE-APACHE-2.0 NOTICE; do
    [ -f "$f" ] && cp "$f" "$PREFIX/$f"
  done
  for src in "$MLX_STAGE"/lib/*.dylib; do cp "$src" "$LIBDIR/"; done
  cp "$MLX_STAGE/lib/mlx.metallib" "$LIBDIR/"
  [ -f "$LLAMA_DIR/libllama.dylib" ] && cp "$LLAMA_DIR/libllama.dylib" "$LIBDIR/"
  mv "$PREFIX/mlx-serve.tmp" "$PREFIX/mlx-serve"
fi

# ── Rewire: every reference must resolve inside the prefix ───────────────────
rewrite mlx-serve         "$BIN"                         @rpath/libmlxc.dylib  @executable_path/lib/libmlxc.dylib
rewrite mlx-serve         "$BIN"                         @rpath/libllama.dylib @executable_path/lib/libllama.dylib
rewrite lib/libmlxc.dylib "$MLX_STAGE/lib/libmlxc.dylib" @rpath/libmlx.dylib   @loader_path/libmlx.dylib

# libjaccl and any future @rpath sibling of libmlx resolves inside lib/.
plan "add-rpath @loader_path in lib/libmlx.dylib"
[ "$DRY_RUN" = 1 ] || install_name_tool -add_rpath @loader_path "$LIBDIR/libmlx.dylib" 2>/dev/null || true

# Third-party dylibs the binary links by absolute Homebrew path: bundle the file
# it really links, under the name it really asks for, then fix that file's own
# Homebrew deps (libwebp -> libsharpyuv) one level down.
BREW_DEPS="$(dep_pairs "$BIN" || true)"
if [ -n "$BREW_DEPS" ]; then
  BUNDLED=""
  while IFS=$'\t' read -r ref src; do
    [ -n "$ref" ] || continue
    from="$(bundle_src "$ref" "$src")"
    [ -n "$from" ] || continue
    base="$(basename "$from")"
    run rm -f "$LIBDIR/$base"
    run cp "$from" "$LIBDIR/$base"
    rewrite mlx-serve "$BIN" "$ref" "@executable_path/lib/$base"
    BUNDLED="$BUNDLED $from:$base"
  done <<< "$BREW_DEPS"
  for pair in $BUNDLED; do
    src="${pair%:*}"; base="${pair##*:}"
    [ -f "$src" ] || continue
    while IFS=$'\t' read -r sub subs; do
      [ -n "$sub" ] || continue
      subfrom="$(bundle_src "$sub" "$subs")"
      [ -n "$subfrom" ] || continue
      subbase="$(basename "$subfrom")"
      [ -f "$LIBDIR/$subbase" ] || { run rm -f "$LIBDIR/$subbase"; run cp "$subfrom" "$LIBDIR/$subbase"; }
      rewrite "lib/$base" "$src" "$sub" "@loader_path/$subbase"
    done <<< "$(dep_pairs "$src" || true)"
  done
else
  note "mlx-serve links no third-party dylib path — nothing extra to bundle"
fi

# ── Sign: install_name_tool invalidated every signature it touched ──────────
if [ "$DO_SIGN" = 1 ]; then
  for lib in "$LIBDIR"/*.dylib; do
    [ -f "$lib" ] || continue
    plan "sign $lib"
    [ "$DRY_RUN" = 1 ] || codesign --force --sign - "$lib"
  done
  plan "sign $PREFIX/mlx-serve"
  [ "$DRY_RUN" = 1 ] || codesign --force --sign - "$PREFIX/mlx-serve"
else
  note "--no-sign: skipped codesign — the rewrite invalidates the linker signature, so this build is for local experiments only"
fi

if [ "$DO_LINK" = 1 ]; then
  [ -e "$LINK" ] && [ ! -L "$LINK" ] && die "$LINK exists and is not a symlink — refusing to overwrite it (use --link PATH or --no-link)"
  plan "link $LINK -> $PREFIX/mlx-serve"
  if [ "$DRY_RUN" = 0 ]; then
    mkdir -p "$(dirname "$LINK")"
    ln -sfn "$PREFIX/mlx-serve" "$LINK"
  fi
fi
[ "$DRY_RUN" = 1 ] && exit 0

# ── Verify: a reference that only resolves here is a broken install ──────────
LEFT_RPATH="$(otool -L "$PREFIX/mlx-serve" | grep -c '@rpath/' || true)"
[ "$LEFT_RPATH" = 0 ] || die "$PREFIX/mlx-serve still has $LEFT_RPATH @rpath reference(s): $(otool -L "$PREFIX/mlx-serve" | grep '@rpath/' | awk '{print $1}' | tr '\n' ' ')"
LEFT_ABS="$(dep_pairs "$PREFIX/mlx-serve" | cut -f1 || true)"
if [ -n "$LEFT_ABS" ] && [ "$ALLOW_SYSTEM_WEBP" = 0 ]; then
  die "$PREFIX/mlx-serve still links a machine-specific path: $(echo "$LEFT_ABS" | tr '\n' ' ')"
elif [ -n "$LEFT_ABS" ]; then
  note "--allow-system-webp: left in place $(echo "$LEFT_ABS" | tr '\n' ' ') — this install needs that path on the target Mac"
fi
[ -f "$LIBDIR/mlx.metallib" ] || die "$LIBDIR/mlx.metallib missing — the server would die at startup on 'Failed to load the default metallib'"
# A rewritten name pointing at a dylib we never copied is the same dyld death on
# the receiver, just under a different prefix.
for ref in $(otool -L "$PREFIX/mlx-serve" | awk 'NR>1{print $1}'); do
  case "$ref" in
    @executable_path/lib/*) [ -f "$LIBDIR/${ref#@executable_path/lib/}" ] || die "$PREFIX/mlx-serve asks for $ref, which is not in $LIBDIR" ;;
    @rpath/*) ;; # refused above
  esac
done
[ "$DO_SIGN" = 1 ] && { codesign --verify "$PREFIX/mlx-serve" || die "codesign --verify failed on $PREFIX/mlx-serve"; }

# A dylib nothing links is a decoy: it looks like a bundled dependency, sits on
# disk, and hides the fact that the binary still resolves the dependency
# elsewhere. Removing it is why an earlier install's lib/libwebp.dylib should not
# survive to mislead the next reader.
if [ "$PRUNE" = 1 ]; then
  WANTED="$( { otool -L "$PREFIX/mlx-serve"; for d in "$LIBDIR"/*.dylib; do [ -f "$d" ] && otool -L "$d"; done; } \
            | awk '{print $1}' | grep -E '^@(executable_path|loader_path)/' | awk -F/ '{print $NF}' | sort -u || true )"
  # An empty WANTED is this script failing to read the load commands, not an
  # unreferenced prefix: pruning then would delete the runtime it just staged.
  if [ -z "$WANTED" ]; then
    note "prune skipped: no @executable_path/@loader_path references read back from $PREFIX/mlx-serve"
  else
    for d in "$LIBDIR"/*.dylib; do
      [ -f "$d" ] || continue
      echo "$WANTED" | grep -qxF "$(basename "$d")" && continue
      note "removing unreferenced $(basename "$d") — nothing in the prefix links it (--keep-unreferenced to keep it)"
      rm -f "$d"
    done
  fi
fi

if [ "$DO_SIGN" = 1 ]; then
  "$PREFIX/mlx-serve" --version
else
  note "--no-sign: not running the binary (macOS refuses an unsigned rewrite on some setups)"
fi
note "installed to $PREFIX ($(du -sh "$PREFIX" | awk '{print $1}'))"
[ "$DO_LINK" = 1 ] && note "linked at $LINK"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) [ "$DO_LINK" = 1 ] && note "NOTE: \$HOME/.local/bin is not on PATH" ;;
esac
[ -n "$RUNNING" ] && note "pid ${RUNNING// /, } still runs the previous bytes — restart it to take this install"
exit 0
