# Dump formats

MemNixFS supports four on-disk formats today: AVML, LiME, raw, and
kdump/vmcore (ELF64 `ET_CORE`). All are auto-detected by
`format_factory.cpp` peeking at the first few bytes — you never have to
tell the tool which format the dump is.

## AVML (Microsoft Azure Memory Loader)

**File extensions:** `.lime.compressed`, `.avml`, sometimes `.lime`
**Source:** [microsoft/avml](https://github.com/microsoft/avml)
**Use case:** Most common modern Linux dump format. Compact (Snappy-compressed),
preserves sparse layout, doesn't crash on `/dev/crash` access denied.

### Format on disk
```
[AVML header — "ELF\x7F" + AVML magic + version]
[range descriptor: PA_start, PA_end, offset_into_file]
[range descriptor]
…
[Snappy-framed compressed page chunks]
```

Each chunk is a sequence of Snappy frames; each frame decompresses to
exactly one 4 KiB page or one 2 MiB hugepage.

### Reader
`src/formats/avml_format.cpp` — `AvmlPhysicalLayer`. Indexes all chunks
at open time, then for each `read(pa, n)` decompresses the chunk(s)
that cover the requested range.

### Notes
- **Sparse**: regions not in any AVML chunk read as all-zero. This is
  faithful to what AVML captured — `/proc/kcore` exposes only mapped
  pages, so gaps in the address space genuinely contain nothing.
- AVML chunks can have small gaps inside the kallsyms region (we hit
  this on the Ubuntu test dump: 3 × 64 KB gaps inside `kallsyms_names`).
  The kallsyms parser is gap-tolerant by design.

### Physical memory model: contiguous sparse image

`PhysicalLayer::read()` zero-fills the output buffer for holes, but its return
value counts only bytes actually backed by captured dump ranges. `/mem/phys.raw`
is the separate sparse stream view that returns synthetic zeros across gaps for
hex editors and `dd`. Those zeros are stream fill, not proof that the source
memory contained zeros. `/sys/mem_ranges.txt` lists captured physical ranges
when the dump format can report them.

Physical memory is presented as a **contiguous sparse image**. Addresses
the dump never captured — interior gaps between AVML frames, or addresses
past the last frame — read as zeros, and a read never short-circuits when
it hits a gap: it spans the hole (zero-filling the missing bytes) and keeps
going. This is what makes `/mem/phys.raw` a complete end-to-end image, and
it lets page-cache content recovery treat any missing frame as zero-fill
rather than a hard stop.

(Previously the AVML reader returned only the count of bytes it actually
copied from frames, so a read landing on a sparse gap came back short and
`/mem/phys.raw` truncated at the first hole. Fixed in **v0.31**.)

## LiME

**File extensions:** `.lime`
**Source:** [504ensicslabs/LiME](https://github.com/504ensicslabs/LiME)
**Use case:** Older Linux memory acquisitions. Kernel module-based; can
acquire memory on a running system without kernel debugger.

### Format on disk
```
[LiME header: magic 0x4C694D45 ("EMiL"), version, S_addr, E_addr, reserved]
[raw bytes from S_addr..E_addr]
[LiME header for next range]
[raw bytes]
…
```

Uncompressed. Each LiME-described range is contiguous in the file.

### Reader
`src/formats/lime_format.cpp` - `LimePhysicalLayer`. Reads all range
headers at open time, verifies that every declared range has enough bytes
remaining in the file, then translates PA to file offset directly. A LiME
file whose final segment extends past EOF is treated as truncated instead of
silently reading the missing tail as zeros.

## Raw

**File extensions:** anything (no magic check)
**Source:** `dd if=/dev/mem`, QEMU `pmemsave`, hypervisor dumps, etc.
**Use case:** "I have N bytes of physical memory, starting at PA 0".

### Format on disk
Exactly that. PA `X` is at file offset `X`. No magic, no chunking.

### Reader
`src/formats/raw_format.cpp` — `RawPhysicalLayer`. Trivial: it's the
identity mapping.

### When to use raw
- **QEMU `pmemsave`** — the recommended way to produce a gap-free
  dump for testing. See [Creating test dumps](../recipes/creating-test-dumps.md).
- **Hypervisor exports** — VMware `.vmem`, VirtualBox `.elf` (extract
  PT_LOAD), KVM `virsh dump`.
- **Live `/proc/kcore`** (when we add a reader for the ELF wrapper) —
  not yet supported.

## Format detection

`open_physical_layer(source)` in `src/formats/format_factory.cpp`:

```cpp
1. Peek 64 bytes from offset 0
2. If bytes start with "ELF\x7F" AND look like AVML → use AvmlPhysicalLayer
3. Else if first 4 bytes == 0x4C694D45 (LiME magic) → use LimePhysicalLayer
4. Else → use RawPhysicalLayer
```

Log line on open:

```
[INF] Format: AVML (Microsoft Azure Memory Loader)
[INF] AVML: 32248 chunk-frames, max PA = 0x7fffffff
```

or

```
[INF] Format: raw (no recognized header at offset 0)
```

## kdump / vmcore (ELF core)

**File extensions:** `vmcore`, `.elf`
**Use case:** Crashed-kernel dumps produced by `kdump`.

Supported since **v0.12**. `src/formats/kdump_format.cpp` —
auto-detected on `\x7fELF` magic; reads `PT_LOAD` segments for PA
mapping and `PT_NOTE` for VMCOREINFO. (Validation against a real kdump
capture is still pending; VMCOREINFO is captured but not yet consumed
for kernel resolution.)

## Future: more formats

| Format | Tracking | Notes |
|---|---|---|
| QCOW2 | not planned | Disk image, not memory |
| VMware `.vmsn` | maybe | Used by some forensics workflows |
| VirtualBox `.elf` | maybe | Same |

## Choosing a format when acquiring

| Goal | Recommended tool |
|---|---|
| Quick acquisition on a running Linux system | AVML (`avml -c output.lime.compressed`) |
| Reproducible test dump | QEMU `pmemsave` (see [recipes](../recipes/creating-test-dumps.md)) |
| Crashed kernel | `kdump` (v0.12 — readable; VMCOREINFO captured but not yet used for kernel resolution) |
| Live triage | Read `/proc/kcore` directly (we don't support yet) |
