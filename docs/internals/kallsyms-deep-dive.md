# kallsyms — Deep dive

Bit-level details of how Linux `kallsyms` is laid out in physical
memory, and how our parser navigates it. Read this if you're debugging
a kernel where the parser fails, or porting to a new architecture.

For the high-level overview, see [features/kallsyms](../features/kallsyms.md).

## On-disk layout (in the kernel binary)

In a modern `CONFIG_KALLSYMS_BASE_RELATIVE=y` kernel, the standard
order emitted by `scripts/kallsyms.c` is:

```
┌─────────────────────────────────────────────────────────┐
│ kallsyms_offsets[N]            (i32 each, 4·N bytes)    │
├─────────────────────────────────────────────────────────┤
│ kallsyms_relative_base         (u64, 8 bytes)           │
├─────────────────────────────────────────────────────────┤
│ kallsyms_seqs_of_names[N]      (u32 each, 4·N bytes)    │ ← only present
│                                                         │   on kernel ≥ 6.2
├─────────────────────────────────────────────────────────┤
│ kallsyms_num_syms              (u32, 4 bytes)           │
├─────────────────────────────────────────────────────────┤
│ kallsyms_names[*]              (compressed names)       │
├─────────────────────────────────────────────────────────┤
│ kallsyms_markers[M]            (u32 or u64 each)        │ ← width depends
│                                                         │   on kernel age
├─────────────────────────────────────────────────────────┤
│ kallsyms_token_table[*]        (256 NUL-term strings)   │
├─────────────────────────────────────────────────────────┤
│ kallsyms_token_index[256]      (u16 each, 512 bytes)    │
└─────────────────────────────────────────────────────────┘
```

Each label is preceded by `ALGN` (on x86_64 = `.p2align 4` = 16-byte
alignment). So between consecutive sections there can be 0–15 bytes of
padding.

### "Alpine-style trailing" layout

On some kernels (notably Alpine `linux-virt`), the linker reorders
sections such that `offsets` and `relative_base` end up AFTER
`token_index`:

```
… num_syms … names … markers … token_table … token_index … offsets[N] … relative_base
```

This happens because `scripts/kallsyms.c` emits each table inside its
own `.section ".rodata"` block; if other compilation units contribute
.rodata between, the linker can reorder. MemNixFS detects and handles
both layouts.

## Encoding details

### `kallsyms_names` — compressed names

A sequence of length-prefixed entries:

```
[len_byte] [token_idx] [token_idx] … [token_idx]  ← entry 0
[len_byte] [token_idx] [token_idx] …               ← entry 1
…
```

- `len_byte` ∈ [1, 127]: 1-byte length encoding. The entry is `1 + len`
  bytes long.
- `len_byte` with high bit set (0x80–0xFF): **2-byte length**. The
  actual length is `(len_byte & 0x7F) | (next_byte << 7)`. Used since
  kernel 6.7 for symbol names ≥ 128 chars.
- Length 0 is invalid (never produced by the kernel).

Each `token_idx` is a u8 index into `kallsyms_token_index`, which gives
the offset of token `idx` in `kallsyms_token_table`.

The decoded entry is: `type_char` (1st char of the first token) +
`name` (the rest). E.g. a 9-byte decoded string `"Tinit_task"` →
type='T', name="init_task".

### `kallsyms_token_table` — token strings

256 NUL-terminated short strings, concatenated. Typically ~600–1500
bytes total. Example fragment from Alpine 6.12:

```
… 'QU\0' 'tf\0' 'tl\0' 'ip\0' 'UN\0' 'ic\0' 'st\0' 're\0' …
```

The kernel build's `scripts/kallsyms.c` finds the most-common
n-grams across the kernel's symbol names and stores them as tokens,
producing significant compression (~3:1).

### `kallsyms_token_index` — token offsets

Exactly 256 × `u16`. `token_index[i]` is the byte offset of token `i`
within `kallsyms_token_table`. Constraints:

- `token_index[0] == 0`
- Monotonically non-decreasing
- `token_index[255] < 2048`
- 16-byte aligned (`.p2align 4`)

These constraints are how we find the table in physical memory.

### `kallsyms_markers` — fast-jump offsets

`M = ceil(num_syms / 256)` entries. `markers[i]` is the byte offset
within `kallsyms_names` where the i'th batch of 256 symbols starts:

- `markers[0] = 0`
- `markers[1] = bytes_in_first_256_entries`
- `markers[i+1] − markers[i]` = bytes in the i'th batch
- `markers[M-1] ≤ markers[M-2] + 256 × max_entry_size`

Used by the kernel to skip ahead to a target symbol without parsing
every byte of `kallsyms_names`.

Width has changed:

| Kernel | Entry width | Reason |
|---|---|---|
| Pre-~6.0 | `sizeof(unsigned long)` = 8 on x86_64 | Default `unsigned long` |
| ~6.0+ | `u32` | Commit "kallsyms: reduce size by switching markers from unsigned long to u32" |
| 32-bit (any age) | 4 bytes | Native `unsigned long` is 32-bit |

### `kallsyms_offsets` + `kallsyms_relative_base`

For `CONFIG_KALLSYMS_BASE_RELATIVE=y`:

- `relative_base` is a u64 kernel image VA (typically `_text`).
- `offsets[i]` is an `i32` that decodes to symbol `i`'s VA:

```c
// From kernel/kallsyms_internal.h
unsigned long kallsyms_sym_address(int idx)
{
    if (kallsyms_offsets[idx] >= 0)
        return kallsyms_relative_base + (u32)kallsyms_offsets[idx];

    /* offset is negative → absolute address (percpu / etc.) */
    return kallsyms_relative_base - 1 - kallsyms_offsets[idx];
}
```

The negative-offset path is **`CONFIG_KALLSYMS_ABSOLUTE_PERCPU`**.
Percpu variables and other VAs outside `[_text, _etext)` are encoded
as `-(absolute_VA + 1)`. Decoded: `addr = relative_base − 1 − offset`.
Equivalent to `addr = relative_base + ~offset` (in unsigned 64-bit).

### Pre-`CONFIG_KALLSYMS_BASE_RELATIVE` (< Linux 4.6)

No `offsets[]`, no `relative_base`. Instead:

```
kallsyms_addresses[N]   (u64 each — full VAs)
kallsyms_num_syms       (u32)
kallsyms_names          (compressed names)
…
```

**Not yet supported by MemNixFS.** Tracked as future work.

## Parser algorithm (recap)

### Stage 1: `token_index` signature scan

Scan all of physical memory in 4 MiB chunks. At each 2-aligned position,
read 512 bytes as a `u16[256]`. Validate:

| Constraint | Why |
|---|---|
| `v[0] == 0` | token 0 starts at offset 0 |
| `v[255] ∈ [256, 2048)` | sane token table size |
| Monotonic non-decreasing | offsets always grow |
| All `v[i+1] − v[i] ≤ 40` | no token longer than ~40 chars |
| `≥ 200` non-empty deltas | most tokens non-empty |

Rank surviving hits by alignment: 16-byte aligned first (real kallsyms),
then 8, 4, 2.

### Stage 2: `token_table` validation

For each candidate `token_index` PA, scan **backwards** for the actual
`token_table`. Try every total-size `S = v[255] + 1, v[255] + 2, …`:

- The byte at position `S − 1` from the table start must be NUL
- For each `i ∈ [1, 255]`, the byte at position `v[i] − 1` must be NUL
- ≥ 90% of non-NUL bytes are in `[A-Za-z0-9_$. ]`

First `S` that satisfies all → that's the table size and start.

### Stage 3: Marker walk

For each width ∈ {4, 8}, walk backward from `token_table_pa − width`:

- Read u32 (or u64) values, going down
- Skip exactly 1 leading zero (alignment padding)
- Accumulate strictly-decreasing values < 64 MiB
- Stop at the next 0 (that's `markers[0]`)

Both widths' walks are tried; the one producing a self-consistent
markers array wins.

**Bug we hit:** The leading-zero is read but not added to `markers`,
yet the count formula `(scan_top + width) − width × size` implicitly
includes it, shifting `markers_pa` by `width`. Fix: subtract
`width × zero_padding` from the end before computing `markers_pa`.

### Stage 4: Names anchor (last batch)

The naive forward walk of all of `kallsyms_names` doesn't work on
gappy dumps. Instead:

- The LAST batch (1–256 entries, ~3 KB) sits right before markers
- For each `padding ∈ [0..7]`:
  - For each `K ∈ [2..16384]` (byte size of the last batch):
    - `last_batch_start_pa = markers_pa − padding − K`
    - Walk forward from there, parse `K` bytes
    - Count entries; require `cnt ∈ [1, 256]`
    - Require walk ends exactly at `markers_pa − padding`
  - First match: `nsyms = 256 × (M−1) + cnt`
- Cross-validate: walk 256 entries from `names_pa`; should total
  exactly `markers[1]` bytes

### Stage 5: `num_syms_pa` location

The u32 `num_syms` value is now known (computed in Stage 4). Scan
4-aligned positions in `[names_pa − 16, names_pa)` for the u32 ==
`nsyms`. First match is `num_syms_pa`.

(This step exists because the `.balign` padding between `num_syms` and
`names` is 0, 4, 8, or 12 bytes — not always 4.)

### Stage 6: `offsets` + `relative_base` discovery

Try both layouts:

**Standard:** sweep 8-aligned positions in `[num_syms_pa − 24,
num_syms_pa)` for a u64 with top 4 bytes `== 0xFFFFFFFF`. That's
`relative_base`. Then `offsets_pa = relative_base_pa − 4·N` (with
0–32 bytes alignment slack).

**Alpine trailing:** `offsets_pa = token_index_pa + 512` (right after
the 512-byte token_index). Read N i32 entries; the byte after them
(with 0–24 bytes slack, 8-aligned) is `relative_base`.

Sanity check: ≥ 50% non-zero offsets, ≥ 90% in `[-2^30, 2^30)`.

### Stage 7: Decode each entry

For each symbol `i`:

```cpp
// Decode the length-prefixed name from kallsyms_names
u8 b0 = names[cur];
u32 len, hdr_size;
if (b0 & 0x80) {
    len = (b0 & 0x7F) | (names[cur+1] << 7);
    hdr_size = 2;
} else {
    len = b0;
    hdr_size = 1;
}
cur += hdr_size;

// Expand `len` tokens
std::string decoded;
for (u32 j = 0; j < len; ++j) {
    decoded += token_table[token_index[names[cur + j]]];
}
cur += len;

// First char of decoded string is the type code
char type = decoded[0];
std::string name = decoded.substr(1);

// Decode address
u64 address;
if (offsets[i] >= 0) {
    address = relative_base + (u32)offsets[i];
} else {
    address = relative_base − 1 − offsets[i];
}
```

## Type characters

Same as `nm`(1) output:

| Char | Meaning |
|---|---|
| `T` | Text, global |
| `t` | Text, local (static) |
| `D` | Data, global |
| `d` | Data, local |
| `B` | BSS, global |
| `b` | BSS, local |
| `R` | Read-only data, global |
| `r` | Read-only data, local |
| `A` | Absolute (percpu, vsyscall, etc.) |
| `?` | Unknown |

## Why the last-batch anchor is critical

For the bundled AVML dump:

- `kallsyms_names` is 2.86 MB
- Three 64-KB chunks of names data are in dump gaps (AVML didn't capture them)
- A naive forward walk crashes on the first gap (length byte = 0 → invalid)

The last-batch anchor only reads ~3 KB at the end of names, which is in
the dump-mapped region. From there, we know `names_pa` exactly. Then
we can extract every symbol whose offset → batch falls in mapped pages,
and report 0 for the unreachable ones.

For gap-free dumps (QEMU `pmemsave`, kdump, live `/proc/kcore`),
everything is reachable and 100% of symbols resolve.

## Reference

- `kernel/kallsyms.c` — the runtime kernel side
- `kernel/kallsyms_internal.h` — `kallsyms_sym_address()` formula
- `scripts/kallsyms.c` — the build-time generator (the source of all
  truth about layout)
- `include/linux/kallsyms.h` — public interface
- `init/Kconfig` — `CONFIG_KALLSYMS_*` options
- Volatility 3: `volatility3/framework/plugins/linux/kallsyms.py` (the
  Python reference implementation we derived the algorithm from)
