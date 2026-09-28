#!/usr/bin/env python3
"""Make a raw-BF16 `ngram_table.bin` out of a PLEBF16 GGUF split, for ~0 bytes.

The GGUF splits that keep the n-gram PLE table undistilled (`*-PLEBF16-*`) hold
`per_layer_token_embd.weight` as BF16 ggml type 30 with dims
`[row_dimension, row_count]`. ggml dims are fastest-axis-first, so the PAYLOAD
BYTES are already row-major `[row_count, row_dimension]` — exactly what
`NgramTable.row`'s raw (bits 16) arm reads, in the row order `NgramHash.rowIds`
indexes. So the "conversion" is: write a safetensors-format header in front of
those bytes and change nothing else.

That is only cheap if the header lands where the GGUF's data already starts:
`general.alignment` (default 32) puts the payload at `align_up(header_end, 32)`
= 192 on the Qwen3.8-Flash-Next split, and `NgramTable` is happy with a header
of any length, so we pad our JSON to exactly `data_start - 8` and the payload
NEVER MOVES. Hence: `cp -c` (APFS clone, copy-on-write, ~4 KiB of new blocks
for the patched header page) and patch the clone's first `data_start` bytes.

    python3 tests/gguf_ple_to_ngram_table.py --gguf <part.gguf> --out <ngram_table.bin>
    python3 tests/gguf_ple_to_ngram_table.py --self-test

Refuses (never silently mangles): a split whose payload is not EXACTLY one BF16
PLE tensor to EOF (a truncated download, or a GGUF that interleaves other
tensors — the payload would need a real copy); a header whose JSON will not fit
in `data_start - 8` even without the `format` stamp; a row count that is not a
multiple of 4 (a `row_dimension`/`row_count` misread).

The table keeps `group_size` in `__metadata__` because `NgramTable.parse` still
requires the key for every width, raw included (it is unused by the raw arm);
the value written is `1`.

Self-test builds a tiny GGUF (same header rules, filler KVs so the data start
lands near the real 192), clones+patches it, and asserts the payload bytes are
byte-identical before and after the patch — the only claim this tool makes.
"""
import argparse
import json
import os
import struct
import subprocess
import sys
import tempfile

GGUF_TYPE_BF16 = 30
NGRAM_TENSOR = "per_layer_token_embd.weight"
DEFAULT_ALIGNMENT = 32


# ── GGUF reading ────────────────────────────────────────────────────────────

class Reader:
    """GGUF v2/v3 metadata + tensor infos, and where the payload starts."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            if f.read(4) != b"GGUF":
                raise ValueError("not a GGUF file")
            version = self._u32(f)
            if version < 2:
                raise ValueError("GGUF v1 has no standard metadata layout")
            self.n_tensors = self._u64(f)
            self.kv = {}
            for _ in range(self._u64(f)):
                key = self._string(f)
                kind = self._u32(f)
                self.kv[key] = (kind, self._value(f, kind))
            self.tensors = {}
            for _ in range(self.n_tensors):
                name = self._string(f)
                dims = [self._u64(f) for _ in range(self._u32(f))]
                dtype = self._u32(f)
                offset = self._u64(f)
                self.tensors[name] = (dtype, dims, offset)
            self.data_start = self._align(f.tell(), self.kv.get("general.alignment", (4, DEFAULT_ALIGNMENT))[1])

    def _align(self, n, a):
        return (n + a - 1) // a * a

    def _u32(self, f):
        return struct.unpack("<I", f.read(4))[0]

    def _u64(self, f):
        return struct.unpack("<Q", f.read(8))[0]

    def _string(self, f):
        return f.read(self._u64(f)).decode("utf-8")

    def _value(self, f, kind):
        scalars = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f",
                   7: "<B", 10: "<Q", 11: "<q", 12: "<d"}
        if kind == 8:
            return self._string(f)
        if kind == 9:
            item = self._u32(f)
            n = self._u64(f)
            if item == 8:
                return [self._string(f) for _ in range(n)]
            fmt = scalars[item][1]
            return list(struct.unpack("<" + fmt * n, f.read(struct.calcsize(scalars[item]) * n)))
        return struct.unpack(scalars[kind], f.read(struct.calcsize(scalars[kind])))[0]


def ple_geometry(reader):
    """(rows, dim) of the single raw BF16 PLE tensor, or a refusal."""
    if NGRAM_TENSOR not in reader.tensors:
        raise ValueError("%s not in this split (a PLEBF16 split carries it)" % NGRAM_TENSOR)
    dtype, dims, offset = reader.tensors[NGRAM_TENSOR]
    if dtype != GGUF_TYPE_BF16:
        raise ValueError("%s is ggml type %d, expected BF16 (30): the table was distilled"
                         % (NGRAM_TENSOR, dtype))
    if len(dims) != 2:
        raise ValueError("%s has %d dims, expected [row_dimension, row_count]" % (NGRAM_TENSOR, len(dims)))
    dim, rows = dims
    size = rows * dim * 2
    file_size = os.path.getsize(reader.path)
    if offset != 0:
        raise ValueError("PLE tensor does not start at the data section (offset %d): "
                         "this split interleaves other tensors, the payload needs a copy" % offset)
    if reader.data_start + size != file_size:
        raise ValueError("payload (%d B at %d) does not reach EOF (%d B): truncated or trailing junk"
                         % (size, reader.data_start, file_size))
    if rows % 4 or dim % 4:
        raise ValueError("geometry %dx%d unreadable as rows" % (rows, dim))
    return rows, dim


# ── header + patch ──────────────────────────────────────────────────────────

def header_json(rows, dim, stamp=True):
    """The unpadded `ngram_table.bin` header for a raw BF16 table.

    `group_size` is written because `NgramTable.parse` requires the key at every
    width; the raw (16) arm ignores its value.
    """
    meta = {"format": "mlx-serve-ngram", "bits": "16", "group_size": "1"} if stamp \
        else {"bits": "16", "group_size": "1"}
    return json.dumps({"__metadata__": meta,
                       "weight": {"dtype": "BF16", "shape": [rows, dim],
                                  "data_offsets": [0, rows * dim * 2]}}).encode()


def ngram_header(rows, dim, data_off, stamp=True):
    """Header bytes whose length is EXACTLY `data_off - 8`, padded with spaces.

    safetensors-style: `__metadata__` then one `weight` region covering the
    payload. `data_off` is where the payload already sits, so the bytes after
    this header are never touched.
    """
    raw = header_json(rows, dim, stamp)
    if len(raw) > data_off - 8:
        raise ValueError("header json is %d B, only %d B of room before the payload at %d"
                         % (len(raw), data_off - 8, data_off))
    return raw + b" " * (data_off - 8 - len(raw))


def patch_in_place(path, data_start, rows, dim):
    """Overwrite `path`'s first `data_start` bytes with the n-gram header."""
    payload = rows * dim * 2
    if os.path.getsize(path) != data_start + payload:
        raise ValueError("refusing to patch: file is %d B, expected %d B"
                         % (os.path.getsize(path), data_start + payload))
    before = None
    with open(path, "rb") as f:
        f.seek(data_start)
        before = f.read(4096)
    for stamp in (True, False):
        try:
            header = ngram_header(rows, dim, data_start, stamp)
        except ValueError:
            if stamp:
                continue
            raise
        break
    with open(path, "r+b") as f:
        f.write(struct.pack("<Q", len(header)))
        f.write(header)
        f.flush()
        os.fsync(f.fileno())
    with open(path, "rb") as f:
        f.seek(data_start)
        after = f.read(4096)
    if before != after:
        raise ValueError("payload moved at offset %d: patch is not header-only" % data_start)
    return len(header)


def clone(src, dst):
    """APFS clone: shares every block with `src` until one is written."""
    if os.path.exists(dst):
        raise ValueError("refusing to overwrite %s" % dst)
    subprocess.run(["cp", "-c", src, dst], check=True)


def make_table(gguf, out):
    reader = Reader(gguf)
    rows, dim = ple_geometry(reader)
    clone(gguf, out)
    hlen = patch_in_place(out, reader.data_start, rows, dim)
    print("%s: %d rows x %d bf16, payload stays at %d (header %d B, file %d B)"
          % (out, rows, dim, reader.data_start, hlen, os.path.getsize(out)))
    return rows, dim


# ── self-test ───────────────────────────────────────────────────────────────

def _fake_header(rows, dim, dtype=GGUF_TYPE_BF16):
    """Three KVs + one tensor info, like the real PLEBF16 split's own header."""
    kv = [(b"split.no", 2, struct.pack("<H", 3)),
          (b"split.count", 2, struct.pack("<H", 5)),
          (b"qwen4exp.ple.row_count", 10, struct.pack("<Q", rows))]
    body = bytearray()
    for key, kind, value in kv:
        body += struct.pack("<Q", len(key)) + key + struct.pack("<I", kind) + value
    body += struct.pack("<Q", len(NGRAM_TENSOR)) + NGRAM_TENSOR.encode()
    body += struct.pack("<I", 2) + struct.pack("<Q", dim) + struct.pack("<Q", rows)
    body += struct.pack("<I", dtype) + struct.pack("<Q", 0)
    return b"GGUF" + struct.pack("<I", 3) + struct.pack("<Q", 1) + struct.pack("<Q", len(kv)) + bytes(body)


def write_fake_gguf(path, rows, dim, target=192, truncate=0, dtype=GGUF_TYPE_BF16):
    """A one-BF16-tensor GGUF whose payload runs to EOF, like the real split.

    `target` is the data start (the real PLEBF16 split: 192), which fixes how
    much room the n-gram header gets; the header is padded with zeros to it.
    """
    header = _fake_header(rows, dim, dtype)
    if not (target - DEFAULT_ALIGNMENT < len(header) <= target):
        raise ValueError("fake header ends at %d B, which does not align up to a %d B data start"
                         % (len(header), target))
    data_start = target
    payload = bytes((i * 37) % 251 for i in range(rows * dim * 2))
    with open(path, "wb") as f:
        f.write(header + b"\0" * (data_start - len(header)) + payload)
        f.flush()
        if truncate:
            f.truncate(f.tell() - truncate)
    return data_start


PAYLOAD_BYTE = lambda i: (i * 37) % 251   # the fixture's payload formula, pinned by a Zig test


def self_test(fixture_dir=None):
    tmp = fixture_dir or tempfile.mkdtemp(prefix="ngram-selftest-")
    os.makedirs(tmp, exist_ok=True)
    src = os.path.join(tmp, "fake.gguf")
    dst = os.path.join(tmp, "ngram_table.bin")
    rows, dim = 8, 16
    data_start = write_fake_gguf(src, rows, dim)
    assert data_start == 192, data_start        # the room the real split offers
    assert ple_geometry(Reader(src)) == (rows, dim), "fake gguf unreadable by the real reader"
    with open(src, "rb") as f:
        f.seek(data_start)
        payload = f.read()
    assert len(payload) == rows * dim * 2

    make_table(src, dst)

    # The clone's header is what NgramTable.parse reads.
    with open(dst, "rb") as f:
        hlen = struct.unpack("<Q", f.read(8))[0]
        parsed = json.loads(f.read(hlen))
    assert hlen == data_start - 8, (hlen, data_start)
    assert parsed["__metadata__"] == {"format": "mlx-serve-ngram", "bits": "16", "group_size": "1"}, parsed
    assert parsed["weight"] == {"dtype": "BF16", "shape": [rows, dim],
                                "data_offsets": [0, rows * dim * 2]}, parsed
    with open(dst, "rb") as f:
        f.seek(data_start)
        assert f.read() == payload, "payload bytes changed"
    assert os.path.getsize(dst) == data_start + rows * dim * 2

    # Re-patching is a no-op: same bytes, same size (the clone is idempotent).
    patch_in_place(dst, data_start, rows, dim)
    with open(dst, "rb") as f:
        assert struct.unpack("<Q", f.read(8))[0] == hlen
        f.seek(data_start)
        assert f.read() == payload, "re-patch moved payload bytes"

    # A truncated split (payload short of EOF) refuses by name.
    bad = os.path.join(tmp, "truncated.gguf")
    write_fake_gguf(bad, rows, dim, truncate=64)
    try:
        ple_geometry(Reader(bad))
        raise AssertionError("truncated split should refuse")
    except ValueError as e:
        assert "EOF" in str(e), e
    # A distilled table (ggml Q8_0, not BF16) refuses by name: its bytes are
    # not rows, and a silent read would serve a table of noise.
    quant = os.path.join(tmp, "quantized.gguf")
    write_fake_gguf(quant, rows, dim, dtype=8)
    try:
        ple_geometry(Reader(quant))
        raise AssertionError("a quantized PLE tensor should refuse")
    except ValueError as e:
        assert "distilled" in str(e), e

    # Header room: the json must fit in `data_start - 8`, stamp optional.
    wide_rows, wide_dim = 320001536, 160
    stamped, unstamped = header_json(wide_rows, wide_dim, True), header_json(wide_rows, wide_dim, False)
    assert 100 < len(unstamped) < len(stamped) <= 184, (len(unstamped), len(stamped))
    try:
        ngram_header(wide_rows, wide_dim, len(stamped) + 8 - 1, stamp=True)
        raise AssertionError("a data start one byte short of the stamped json should refuse")
    except ValueError as e:
        assert "room" in str(e), e
    # ... and the SAME room is enough without the stamp (the engine accepts an
    # absent format once, loudly), padded to exactly the space available.
    raw = ngram_header(wide_rows, wide_dim, len(unstamped) + 8, stamp=False)
    assert len(raw) == len(unstamped) and json.loads(raw)["__metadata__"].get("format") is None

    print("self-test ok: %s" % os.path.join(tmp, "ngram_table.bin"))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gguf", help="a PLEBF16 split carrying the raw BF16 PLE tensor")
    ap.add_argument("--out", help="the ngram_table.bin to create (an APFS clone of --gguf)")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--fixture-dir", help="with --self-test: leave the patched fixture here")
    args = ap.parse_args()
    if args.self_test:
        return self_test(args.fixture_dir)
    if not args.gguf or not args.out:
        ap.error("--gguf and --out are required (or --self-test)")
    make_table(args.gguf, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
