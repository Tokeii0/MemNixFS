# kallsyms

## What is kallsyms?

`kallsyms` is the kernel's own symbol table — what `/proc/kallsyms`
shows on a running system. It's compiled into every kernel built with
`CONFIG_KALLSYMS=y` (i.e. all distro kernels). It contains every
exported and (with `CONFIG_KALLSYMS_ALL=y`) every static kernel symbol
along with its virtual address.

On a 6.x distro kernel that's typically **100,000 to 250,000 symbols**.

## What MemNixFS does with it

`src/symbols/kallsyms.cpp` extracts this table **directly from the
dump's physical memory** — no ISF, no banner, no KASLR shift required
as input. The output is a `KallsymsResult`:

```cpp
struct KallsymsEntry {
    VAddr       address;  // kernel VA (KASLR-shifted)
    char        type;     // 't', 'T', 'd', 'D', 'b', 'B', 'r', 'R', 'a', 'A', …
    std::string name;
};

struct KallsymsResult {
    bool ok;
    std::vector<KallsymsEntry> symbols;       // all entries
    std::unordered_map<std::string, size_t> by_name;  // fast lookup
    PAddr  token_table_pa, token_index_pa, markers_pa, names_pa,
           num_syms_pa, offsets_pa, relative_base_pa;
    u32    num_syms, num_markers, names_size, token_table_size;
    bool   base_relative;
    VAddr  relative_base;
};
```

This unlocks three things:

1. **`/sys/kallsyms`** — the VFS file in the mount, in
   `/proc/kallsyms` exact format.
2. **ISF symbol section** — kallsyms entries are merged into the
   BTF-derived ISF's `symbols` section, so the engine's `init_task`,
   `linux_banner`, `init_top_pgt` lookups all work.
3. **Standalone CLI command** — `memnixfs --dump <f> kallsyms` runs
   the parser directly, without any other engine stage. Useful for
   triage when the dump is unfamiliar.

## How it works — the 5-stage parser

### Stage 1: `kallsyms_token_index` signature scan

The compressed-symbol-table scheme has a very distinctive
**`kallsyms_token_index`**: exactly 256 × `u16` values where:

- `index[0] == 0`
- Monotonically non-decreasing
- `index[255] < 2048` (max token-table size)
- Consecutive deltas ≤ 40 (no token > 40 chars)
- At least 200/255 deltas are > 1 (most tokens non-empty)
- 16-byte aligned PA (kernel `.p2align 4` directive)

We scan all of physical memory in 4 MiB chunks looking for this shape.
The Alpine test dump produced 20 candidates; the Ubuntu dump 141.
Candidates are sorted so 16-aligned ones are tried first.

### Stage 2: `kallsyms_token_table` validation

Sitting **right before** `token_index` is `kallsyms_token_table`: 256
NUL-terminated short strings whose starting offsets exactly match the
index values. We:

1. Compute the table size from `index[255] + length_of_last_token`.
2. Verify every `index[i]` points to a position one byte after a NUL.
3. Verify ≥ 90% of non-NUL bytes are printable ASCII (`[A-Za-z0-9_$. ]`).

Example tokens from the Alpine dump: `'QU'`, `'tf'`, `'tl'`, `'ip'`,
`'UN'`, … These are short common substrings of kernel symbol names
(determined at kernel-build time by `scripts/kallsyms.c` finding the
most-used n-grams).

### Stage 3: Marker walk (auto-detect u32 vs u64 width)

`kallsyms_markers` is `M = ceil(num_syms / 256)` entries — one offset
into `kallsyms_names` per 256-symbol batch. Entry size has changed
across kernel versions:

| Kernel | Marker entry width |
|---|---|
| pre-~6.0 (64-bit) | 8 bytes (`u64`) |
| 6.0+ | 4 bytes (`u32`) — the "shrink kallsyms data" series |
| 32-bit (always) | 4 bytes |

Our walker tries 4-byte first, then 8-byte. For each:
- Walk backwards from `token_table_pa − width`
- Skip at most 1 leading zero (alignment padding between markers
  and token_table)
- Accumulate strictly-decreasing values < 64 MiB
- Stop when we read 0 (that's `markers[0]`)

Catch: the loop ALSO includes 1 leading-zero in its count, which
shifts `markers_pa` by `width`. The `MarkersResult.pa` calculation
subtracts `width × zero_padding` to compensate (this was the
"markers off-by-4" bug we fixed during development).

### Stage 4: `kallsyms_names` anchor + cross-validate

`kallsyms_names` is a sequence of length-prefixed compressed entries:

```
[len_byte] [token_idx] [token_idx] … [token_idx]
[len_byte] [token_idx] [token_idx] …
…
```

For kernel ≥ 6.7, `len_byte` can be a 2-byte encoding when name length
≥ 128:

```
if (len_byte & 0x80):
    len = (len_byte & 0x7F) | (next_byte << 7)
    skip 2 bytes
else:
    len = len_byte
    skip 1 byte
```

A naive forward walk from a candidate `names_pa` through all entries
would have to read every byte of names — but on the AVML test dump,
~192 KB of `names` is in dump gaps. So we anchor on the **last batch**:

1. The last batch has 1–256 entries, typically ~3 KB
2. It sits right before `kallsyms_markers` (with 0–7 bytes
   `.balign` padding)
3. We try each `padding ∈ [0..7]` and each batch-byte-size
   `K ∈ [2..16384]`:
   - `last_batch_start = markers_pa − padding − K`
   - Walk forward `K` bytes, count entries
   - Require: walk ends exactly at `markers_pa − padding`, count
     ∈ [1, 256]
4. From the matching `K`: `nsyms = 256 × (M−1) + count`
5. Reject if `nsyms ∉ [n_min, n_max]` (derived from M)

**Cross-validation**: walk 256 entries from the deduced `names_pa`;
they should total exactly `markers[1]` bytes. This filters spurious
matches that happen to land correctly on the last-batch boundary.

### Stage 5: `kallsyms_offsets` + `kallsyms_relative_base`

Two layouts in the wild:

**Standard layout** (most kernels — Ubuntu, Fedora, RHEL):
```
… offsets[N] … relative_base … [seqs_of_names[N]] … num_syms … names … markers … token_table … token_index
```

**Alpine-style "trailing" layout** (Alpine `linux-virt`):
```
… num_syms … names … markers … token_table … token_index … offsets[N] … relative_base
```

The Alpine layout is a linker artefact: `scripts/kallsyms.c` emits each
table with its own `.section ".rodata"` directive, and depending on
other `.o` file contributions, the linker can reorder them.

We try **both**:
- Standard: scan 8-byte aligned positions in `[num_syms_pa−24, num_syms_pa)`
  for a `u64` matching the kernel-VA pattern (`top 4 bytes == 0xFFFFFFFF`).
- Trailing: `offsets_pa = token_index_end_pa`, scan immediately after
  for the same kernel-VA pattern.

Either match triggers a sanity check (≥ 50% non-zero offsets, ≥ 90%
in `[-2^30, 2^30)`).

### Stage 6: Address decode

For each symbol, given its offset and `relative_base`:

```cpp
if (offsets[i] >= 0) {
    // Standard relative-offset symbol
    VA = relative_base + (u32)offsets[i];
} else {
    // CONFIG_KALLSYMS_ABSOLUTE_PERCPU symbol (percpu / absolute VAs)
    VA = relative_base − 1 − offsets[i];
    // Equivalent: VA = relative_base + ~(i32 cast to u64)
}
```

This formula is **straight from the kernel** (`kernel/kallsyms_internal.h`).
The negative-offset path handles percpu variables and other absolute
addresses outside the kernel image range.

## Verified output

### Ubuntu 6.14.0-36-generic

```
$ memnixfs --dump output.lime.compressed kallsyms init_task
0xffffffffa826e2d0 D init_task

$ head -5 /mnt/M/sys/kallsyms
ffffffffa6800000 T _text
ffffffffa6800000 T _stext
ffffffffa6801000 T page_offset_base
ffffffffa6801010 T __init_begin
ffffffffa6801010 T phys_base
```

### Alpine 6.12.1-3-virt (from QEMU)

```
$ memnixfs --dump wsl_kvm.raw kallsyms init_task
0xffffffff9c810940 D init_task

$ wc -l /mnt/M/sys/kallsyms
135809 /mnt/M/sys/kallsyms
```

## Limitations

### Gap tolerance — addresses
`kallsyms_offsets` is ~530 KB; if it's split across dump gaps, the
sanity check rejects (< 50% non-zero) and we fall back to names-only
mode (addresses set to 0). The user sees a clear warning. On a
gap-free dump (QEMU `pmemsave`, kdump, live `/proc/kcore`), addresses
always resolve.

### Pre-CONFIG_KALLSYMS_BASE_RELATIVE
Very old kernels (< 4.6) use `kallsyms_addresses[N]` (u64 each) instead
of `kallsyms_offsets` + `kallsyms_relative_base`. **Not yet supported.**
Tracked as future work. Will need an old-kernel test
dump to validate.

### Cross-arch
The current implementation assumes x86_64. arm64 should mostly work
(same `.p2align 4`, same 8-byte u64 entries) but is **untested**.
Tracked as future work.

### Cosmetic: 4-space artifact in some names
On some kernels, a handful of decoded symbol names show extra
whitespace (e.g. `__       per_cpu_start` instead of `__per_cpu_start`).
Probably a token in `kallsyms_token_table` that legitimately contains
spaces. The name still works for lookups; it's purely a display
artefact. Future work.

## Standalone CLI usage

```powershell
# Bulk view: shows totals + well-known symbol sanity check
memnixfs --dump <file> kallsyms

# Look up one symbol by name
memnixfs --dump <file> kallsyms init_task
# 0xffffffff9c810940 D init_task

memnixfs --dump <file> kallsyms linux_banner
# 0xffffffff9bed7a20 D linux_banner

memnixfs --dump <file> kallsyms do_init_module
# 0xffffffff9b27c4a0 T do_init_module
```

## Reference

- Kernel source: `kernel/kallsyms.c`, `kernel/kallsyms_internal.h`,
  `scripts/kallsyms.c` (the build-time generator)
- Volatility 3 plugin: `volatility3/framework/plugins/linux/kallsyms.py`
- Wiki deep-dive: [internals/kallsyms-deep-dive.md](../internals/kallsyms-deep-dive.md)
