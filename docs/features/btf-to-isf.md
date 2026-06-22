# BTF → ISF

## What is BTF?

BTF (BPF Type Format) is the kernel's compact type information format,
defined in `include/uapi/linux/btf.h`. Kernels built with
`CONFIG_DEBUG_INFO_BTF=y` embed the entire kernel type universe
(structs, unions, enums, typedefs, function prototypes, …) as a small
(~3 MB) blob in the `.BTF` ELF section of vmlinux. Because that blob
lives in the kernel image, it ends up in any memory dump.

**BTF is enabled by default on:**
- Ubuntu 20.04+ (LTS), all currently-supported releases
- Fedora 32+
- RHEL 8.2+, CentOS Stream 8+, Rocky/Alma 8.2+
- Debian Buster (10) backports, Bullseye (11), Bookworm (12), Trixie (13)
- Arch Linux (any current kernel)
- Alpine ≥ 3.16
- openSUSE Tumbleweed, Leap ≥ 15.3
- (Just about every modern distro)

## What this gives us

BTF carries **types only** — no symbol addresses. So BTF alone gives:

- `base_types` (INT, FLOAT)
- `user_types` (STRUCT, UNION — including field offsets, sizes, bitfield encoding)
- `enums` (ENUM, ENUM64)

Combined with [kallsyms](kallsyms.md) (which gives addresses), the
result is a **fully-functional Volatility-3 ISF**, synthesised entirely
from the dump's own bytes. **No vmlinux. No network. No `apt-get`. No
toolchain.**

## How it works

### Phase 1 — Probe (`src/os/linux/btf_probe.cpp`)

Scan all of physical memory in 4 MiB chunks for the BTF magic header:

```
struct btf_header {
    u16 magic;        // 0xEB9F
    u8  version;      // 1
    u8  flags;
    u32 hdr_len;      // typically 24
    u32 type_off;
    u32 type_len;
    u32 str_off;
    u32 str_len;
};
```

For each candidate, validate:
- `magic == 0xEB9F`
- `version == 1`
- `hdr_len` in `[24, 256]` (typically exactly 24)
- `type_len > 0` and `str_len > 0`
- Sane size (1 KiB ≤ total ≤ 64 MiB)

Return all hits sorted by total size descending. The largest is
typically the kernel's main `.BTF` section (3–7 MB). Smaller hits are
per-module BTFs.

### Phase 2 — Parse (`src/symbols/btf_to_isf.cpp`)

Walk the BTF type section. Each type is a `btf_type` (12 bytes) plus
kind-specific variable-length data:

| Kind | Code | Variable data |
|---|---|---|
| `VOID` | 0 | — |
| `INT` | 1 | 4 bytes (encoding flags + bit offset + bit size) |
| `PTR` | 2 | — |
| `ARRAY` | 3 | 12 bytes (`btf_array`: type, index_type, nelems) |
| `STRUCT` | 4 | `vlen × 12 bytes` (`btf_member`: name, type, offset) |
| `UNION` | 5 | same as STRUCT |
| `ENUM` | 6 | `vlen × 8 bytes` (`btf_enum`: name_off, val) |
| `FWD` | 7 | — |
| `TYPEDEF` | 8 | — |
| `VOLATILE` | 9 | — |
| `CONST` | 10 | — |
| `RESTRICT` | 11 | — |
| `FUNC` | 12 | — |
| `FUNC_PROTO` | 13 | `vlen × 8 bytes` (`btf_param`) |
| `VAR` | 14 | 4 bytes (linkage) |
| `DATASEC` | 15 | `vlen × 12 bytes` (`btf_var_secinfo`) |
| `FLOAT` | 16 | — |
| `DECL_TAG` | 17 | 4 bytes (component_idx) |
| `TYPE_TAG` | 18 | — |
| `ENUM64` | 19 | `vlen × 12 bytes` (`btf_enum64`) |

Each entry's name (`name_off`) indexes into the BTF string table.

### Phase 3 — Sanity check

A real kernel BTF has ≥ 15 `INT` types and ≥ 100 `STRUCT`s. If we get
less, the blob is either:
- A false positive (random data starting with `0xEB9F`)
- A per-module BTF (not the kernel main)
- Genuinely corrupt

In any case, we reject the conversion and try the next candidate.

This filter caught a real false positive on the Ubuntu test dump: the
first candidate at PA `0x3031030` (also 6.7 MB, same as the real one)
parsed to "30,900 types" but with a histogram showing kinds 21–31 (way
beyond the highest real kind 19 = `ENUM64`). The sanity check
correctly rejected it; the resolver fell through to the real candidate
at PA `0x23a494d0`.

### Phase 4 — Anonymous-struct flattening

Modern kernel structs nest large **anonymous** sub-structs:

```c
struct mm_struct {
    struct {
        struct maple_tree mm_mt;
        unsigned long mmap_base;
        spinlock_t arg_lock;
        …
    };
    unsigned long cpu_bitmap[];
};
```

The outer `mm_struct` has only 2 BTF fields (one being the anonymous
nested struct). The interesting fields like `mm_mt` are buried inside
the nested type.

Volatility-3 ISFs expect **flat** struct layouts. So we recursively
inline anonymous nested struct/union members into their parent at
`parent_bit_offset + member_bit_offset`. Without this, the engine
would fail with `ISF: type 'mm_struct' has no field 'mm_mt'`.

```
Before flattening:
  mm_struct {
    fields: {
      "cpu_bitmap": { offset: 0x100, … }
      "unnamed_field_0": { offset: 0, type: struct unnamed_85 }
    }
  }

After flattening:
  mm_struct {
    fields: {
      "mm_mt": { offset: 0, type: struct maple_tree }
      "mmap_base": { offset: 0x20, … }
      "arg_lock": { offset: 0x28, … }
      …
      "cpu_bitmap": { offset: 0x100, … }
    }
  }
```

Recursion is bounded at 8 levels (real kernel nesting is ≤ 3).
Name-collisions after flattening get a `_<N>` suffix so no field is lost.

### Phase 5 — Merge kallsyms + emit

If a successful [kallsyms](kallsyms.md) extraction is provided, its
addresses populate the ISF's `symbols` section. We filter to entries
whose names look like valid C identifiers (drop `__pfx_*`, `__cfi_*`,
`.cold.*`, `.constprop.*` build artefacts that are noise to consumers).

Then serialize as Volatility-3 ISF JSON 6.2.0 format, xz-compress,
write to:

```
%LOCALAPPDATA%\MemNixFS\symbols\<release>.json.xz   (Windows)
~/.cache/lmpfs/symbols/<release>.json.xz             (Unix)
```

Subsequent runs hit the cache.

## Verification on real dumps

| Kernel | BTF blob size | Types parsed | Final ISF | Notes |
|---|---|---|---|---|
| Ubuntu 6.14.0-36-generic (AVML) | 6.7 MB | 161,299 BTF entries | 11,253 user_types + 18 base + 2,653 enums = 7 MB xz | All `mm_struct` / `task_struct` / `vm_area_struct` fields resolve |
| Alpine 6.12.1-3-virt (raw) | 4.0 MB | 82,608 BTF entries | 7,400 user_types | Less kernel surface (smaller virt kernel) |

## Limitations

### BTF size vs DWARF
BTF is ~10× smaller than DWARF debug info because it omits everything
that isn't kernel-internal types — no source locations, no inline
function info, no per-CPU variable tracking. For 99% of memory-forensics
work this is fine; for niche cases (offset-of-bitfield-in-anonymous-union-in-template,
etc.) DWARF wins. Fall back to `--vmlinux` if you hit that.

### Pre-CONFIG_DEBUG_INFO_BTF kernels
Kernels older than ~5.x (Ubuntu 18.04, RHEL 7, etc.) don't ship BTF.
For these, you need DWARF — see [Symbol resolution](symbol-resolution.md).

### Custom kernels
If someone built a vanilla kernel themselves without
`CONFIG_DEBUG_INFO_BTF=y`, BTF won't be in the dump. They need to
supply their own ISF or vmlinux. The MemNixFS error message tells them
exactly how.

## Reference

- BTF spec: [`include/uapi/linux/btf.h`](https://elixir.bootlin.com/linux/latest/source/include/uapi/linux/btf.h) in the Linux source
- Volatility-3 ISF format: [vol3 docs](https://volatility3.readthedocs.io/en/latest/symbol-tables.html)
- `pahole -J` (the kernel build tool that emits BTF from DWARF)
- `bpftool btf dump file <vmlinux>` (human-readable view of BTF)
