# Building for macOS 15 (Sequoia)

Release binaries and `brew install mlx-serve` cannot start on Sequoia:

```
MLX error: Failed to load the default metallib. This library is using language
version 4.0 which is not supported on this OS.  ... mlx/c/memory.cpp:69
```

## Why

`scripts/build-mlx.sh` stages mlx at deployment target **26.2** on purpose, so
MLX's NAX (M5 neural-accelerator) gate opens. The deployment target also decides
the Metal **language version** the compiler stamps into `mlx.metallib`: a 26.x
target produces language version 4.0, and the Metal runtime on macOS 15 refuses
to load it. Same reason for the dylibs' `minos 26.2` — dyld would reject those
too, one step earlier.

Nothing needs porting. A Sequoia build is an ordinary source build with the
deployment target lowered to 15.x:

| | Tahoe build (default) | Sequoia build |
|---|---|---|
| mlx + metallib | `MLX_DEPLOYMENT_TARGET=26.2` | `MLX_DEPLOYMENT_TARGET=15.0` |
| server binary minos | 26.2 | `-Dmin-os=15.0` |
| NAX kernels | compiled in | skipped by MLX's own ≥ 26.2 gate |
| Metal language version | 4.0 | 3.x — loads on macOS 15 |

NAX is M5-only (MLX gates dispatch on GPU gen ≥ 17), so M1–M4 lose nothing; on
M5 the Sequoia build runs on the regular GPU path. There is no way to have NAX
and Sequoia at once — that is what issue #230 is about.

## Build and install

Both knobs are wired, so it is the normal build with two flags:

```bash
git clone --recurse-submodules https://github.com/ddalcu/mlx-serve && cd mlx-serve
brew bundle install --file=Brewfile

MLX_DEPLOYMENT_TARGET=15.0 ./scripts/build-mlx.sh     # mlx + mlx-c + metallib
./scripts/fetch-zig.sh && export PATH="$PWD/.zig-toolchain:$PATH"
./scripts/fetch-llama.sh
zig build -Doptimize=ReleaseFast -Dmin-os=15.0
```

Then bundle `zig-out/bin/mlx-serve` with `lib/mlx/lib/*.dylib`,
`lib/mlx/lib/mlx.metallib`, `libllama`, and webp exactly as
[building.md](building.md) / `.github/workflows/release.yml` describe — the
metallib must sit beside `libmlx.dylib`, and it is the metallib, not the binary,
that decides whether the server boots.

`-Dmin-os` takes `15`, `15.0` or `15.0.0` and defaults to `26.2`. Pass it rather
than `-Dtarget=aarch64-macos.15.0`: an explicit target also disables Zig's
native CPU detection, and the server then builds `-mcpu baseline`.

## Verifying without a GPU run

`tests/test_mlx_staged_nax.sh` reads the target out of `lib/mlx/.version` and
expects NAX present at ≥ 26.2 and absent below it, so it passes either way. To
check a metallib on its own, load it against the running OS:

```swift
let dev = MTLCreateSystemDefaultDevice()!
print(try dev.makeLibrary(URL: URL(fileURLWithPath: "lib/mlx.metallib")).functionNames.count)
```

## Caveats

- `-Dmin-os` does not change what `LSMinimumSystemVersion` the Swift app claims,
  and nothing here makes the app distributable: build it ad-hoc signed
  (`APPLE_DEVELOPER_ID` unset) for your own Mac.
- A Tahoe build that silently lost its NAX kernels still fails
  `test_mlx_staged_nax.sh`, which is the point — the assertion follows the
  staged target rather than assuming it.
