# Building from source

You only need this if you're hacking on mlx-serve. To just use it, grab [the app](https://github.com/ddalcu/mlx-serve/releases/latest) or `brew install mlx-serve`.

## Prerequisites

- macOS 26.2+ with Apple Silicon (M1/M2/M3/M4/M5) — the bundled MLX is built at deployment target 26.2 so the M5 neural-accelerator (NAX) kernels ship enabled
- Xcode 26.2+ with the Metal Toolchain component — mlx + mlx-c are pinned submodules compiled by `scripts/build-mlx.sh`, not brew packages, so the NAX kernels the brew bottle silently omits are included. Xcode 26 ships the Metal compiler as a separate download, so if `xcrun -sdk macosx metal --version` fails, run `xcodebuild -downloadComponent MetalToolchain` first
- cmake and libwebp: `brew bundle install --file=Brewfile` from the repo root. cmake builds the mlx submodules, webp decodes images in the vision pipeline (`webp >= 1.6.0`, checked at build time)
- [Zig 0.17 nightly](https://ziglang.org/download/) — staged automatically by `./scripts/fetch-zig.sh` into `.zig-toolchain/`

## App + server

One script builds everything:

```bash
git clone --recurse-submodules https://github.com/ddalcu/mlx-serve && cd mlx-serve
brew bundle install --file=Brewfile
./app/build.sh
open "app/MLX Core.app"
```

`app/build.sh` snaps the pinned submodules back to their commits, stages llama.cpp and the Zig nightly, builds mlx + mlx-c with NAX kernels asserted, compiles the Swift app and the Zig server, then bundles and signs. With no signing identity in the environment it signs ad-hoc and skips notarization, so no Apple developer account is needed. Releases are cut by `.github/workflows/release.yml`.

## Server only

```bash
./scripts/build.sh                                   # mlx + llama + Zig nightly + ReleaseFast server
./scripts/build.sh --sequoia                         # same, deployment floor 15.0 (see below)
```

It is one knob for the deployment floor: the target goes to `scripts/build-mlx.sh`
(`MLX_DEPLOYMENT_TARGET`, which decides MLX's NAX gate **and** the Metal language
version in `mlx.metallib`) and to `zig build -Dmin-os` (the executable's floor) in
the same run, and refuses a floor below the `lib/mlx` that is already staged —
that mismatch boots nowhere. What it runs, if you want to run the steps yourself:

```bash
./scripts/fetch-zig.sh                               # stages the pinned nightly at .zig-toolchain/
export PATH="$PWD/.zig-toolchain:$PATH"
./scripts/fetch-llama.sh && ./scripts/build-mlx.sh   # once, and again on a pin bump
zig build -Doptimize=ReleaseFast                     # always ReleaseFast; Debug is 2-4x slower
```

## Installing a copy that runs anywhere

`zig-out/bin/mlx-serve` finds its dylibs through `@loader_path/../../lib/...`, so
it works inside the repo and nowhere else. `scripts/install.sh` makes it
relocatable — into `~/opt/mlx-serve` with a link at `~/.local/bin/mlx-serve` by
default:

```bash
./scripts/install.sh                                 # --dry-run first prints the plan
./scripts/install.sh --prefix DIR --link PATH
```

It copies the binary, `LICENSE`/`LICENSE-APACHE-2.0`/`NOTICE`, `lib/mlx/lib/*.dylib`,
`mlx.metallib`, `libllama`, and the webp dylibs the binary really links; rewrites
`@rpath/…` and absolute Homebrew references onto `@executable_path/lib/…` and
`@loader_path/…`; re-signs every dylib ad-hoc and then the binary
(`install_name_tool` invalidates the linker signature; `release.yml` does the same
with a Developer ID and `--options runtime`, which a local install must not copy);
and fails if any reference that resolves on this machine only survives. It also
removes a `lib/*.dylib` nothing links — a bundled-looking dylib that the binary
resolves elsewhere hides the fact that the dependency is missing. Guard:
`tests/test_install_prefix.sh`.

## Hermetic tests (Linux too)

The server itself is macOS / Apple Silicon only. The per-step preview encoder (`src/preview.zig` + `src/jpeg.zig` + `src/latent_rgb.zig`) links no MLX and no Homebrew webp, so a Linux Cloud Agent can build and run it — on Linux it is the only step `build.zig` registers:

```bash
./scripts/fetch-zig.sh
export PATH="$PWD/.zig-toolchain:$PATH"
zig build preview-test
```

The same step exists on a Mac and builds the same hermetic artifact, but it is **not** a way to build without a staged mlx: `verifyBrewDeps` and `verifyMlxStage` run at configure time for every step, so `lib/mlx/` must already be built. On a Mac `zig build test` also compiles those files as part of the full suite.

## macOS 15 (Sequoia)

Release binaries need macOS 26.2+: their `mlx.metallib` is Metal language version
4.0, which the Sequoia runtime refuses to load. A Sequoia build is the same
build with a lowered deployment target — one flag in one place:
`./scripts/build.sh --sequoia`, then `./scripts/install.sh`. See
[building-sequoia.md](building-sequoia.md).
