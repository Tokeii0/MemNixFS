# x86_64 page-table walker

`src/arch/x86_64/paging.{h,cpp}` implements a 4-level page-table walker
for translating x86_64 virtual addresses to physical addresses.

## 4-level paging on x86_64

A 64-bit virtual address is divided into:

```
Sign-extended bits 47..63 (canonical)
 │ Bits 47..39: PML4 index (9 bits)
 │  │ Bits 38..30: PDPT index (9 bits)
 │  │  │ Bits 29..21: PD index (9 bits)
 │  │  │  │ Bits 20..12: PT index (9 bits)
 │  │  │  │  │ Bits 11..0: page offset (12 bits)
 ▼  ▼  ▼  ▼  ▼ ▼
 0xFFFFFFFF80000000  ← typical kernel image base
```

Each level is a 4 KiB page of 512 × 8-byte entries (PTEs). The walk:

```
CR3 (PA, the DTB) → PML4[idx0] → PDPT[idx1] → PD[idx2] → PT[idx3] → page+offset
```

Each PTE has a present bit (bit 0), a writable bit (bit 1), a user bit
(bit 2), a page-size bit (bit 7), and so on. The next-level PA is in
bits 12..51.

## Large-page support

The walker handles:

| Size | Resolved at | PSE bit |
|---|---|---|
| 4 KiB | PT level | (always 0 in PTE) |
| 2 MiB | PD level | PD PTE bit 7 = 1 |
| 1 GiB | PDPT level | PDPT PTE bit 7 = 1 |

For 2 MiB / 1 GiB pages, the walk terminates early and the remaining
VA bits become the page offset.

## PageTable class

```cpp
// src/arch/x86_64/paging.h
class PageTable {
public:
    PageTable(const PhysicalLayer& phys, PAddr dtb);

    // Returns number of bytes actually read (0 if VA is unmapped).
    // Partial reads happen when a read crosses a page boundary and
    // some pages map and others don't.
    std::size_t read(VAddr va, void* dst, std::size_t n);

    // Single-PA translation. Returns 0 if unmapped.
    PAddr translate(VAddr va) const;

private:
    const PhysicalLayer& phys_;
    PAddr dtb_;
};
```

### Use cases

| Caller | DTB used | Purpose |
|---|---|---|
| `KernelContext::dtb` | Kernel-VA reads (banner, kallsyms-stack, modules) | `eng->kernel_pt()` |
| `task->mm->pgd` | Per-process user-VA reads (for `proc.dmp`) | One `PageTable` per process |

### Error handling

`read()` zero-fills any byte ranges that fall in unmapped pages. So a
read across a partially-mapped region yields real data where pages
exist and zeros elsewhere. **Never throws.**

This matches the Linux kernel's own behaviour when something reads
`/dev/mem` across a hole.

## Page cache

A naive 1-byte read involves 4 PA reads (one per page-table level).
For sequential reads, the first 4 KiB of data costs:

- 1 PML4 read + 1 PDPT read + 1 PD read + 1 PT read = 4 reads
- Then 4 KiB of payload

For the *next* 4 KiB in the same page-table-leaf-PTE region:
- Same 4 reads (cache miss without a cache)

`src/arch/x86_64/page_cache.cpp` solves this with an LRU cache:

```cpp
class UserPageCache {
public:
    UserPageCache(const PhysicalLayer& phys, PAddr user_pgd,
                  std::size_t max_bytes = 16 * 1024 * 1024);

    std::size_t read(VAddr va, void* dst, std::size_t n);
private:
    PageTable pt_;
    // LRU map: page_aligned_VA → cached 4 KiB
    std::list<std::pair<VAddr, ByteBuf>> lru_;
    std::size_t bytes_cached_ = 0;
    const std::size_t max_bytes_;
};
```

- Per-process: each `Process` has its own cache (different PGD).
- Default 16 MiB per process.
- On a cache hit: zero-copy `memcpy` from the buffer.
- On miss: walk the PGD, cache the 4 KiB result.

Measured 99% hit rate on sequential `proc.dmp` reads. Cuts cost from
"AVML decompress + 4 PA reads" to "one `memcpy`".

## Walking the PGD: code path

```cpp
// src/arch/x86_64/paging.cpp (simplified)
PAddr PageTable::translate(VAddr va) const {
    constexpr u64 SIGN_MASK = 0xFFFF000000000000;
    if ((va & SIGN_MASK) != 0 && (va & SIGN_MASK) != SIGN_MASK)
        return 0;   // non-canonical

    const u64 pml4_idx = (va >> 39) & 0x1FF;
    const u64 pdpt_idx = (va >> 30) & 0x1FF;
    const u64 pd_idx   = (va >> 21) & 0x1FF;
    const u64 pt_idx   = (va >> 12) & 0x1FF;

    u64 pml4_e = read_pte(dtb_ + pml4_idx * 8);
    if (!(pml4_e & 0x1)) return 0;
    PAddr pdpt_pa = pml4_e & 0x000FFFFFFFFFF000ULL;

    u64 pdpt_e = read_pte(pdpt_pa + pdpt_idx * 8);
    if (!(pdpt_e & 0x1)) return 0;
    if (pdpt_e & 0x80) {                                  // 1 GiB page
        PAddr page_pa = pdpt_e & 0x000FFFFFC0000000ULL;
        return page_pa | (va & 0x3FFFFFFF);
    }
    PAddr pd_pa = pdpt_e & 0x000FFFFFFFFFF000ULL;

    u64 pd_e = read_pte(pd_pa + pd_idx * 8);
    if (!(pd_e & 0x1)) return 0;
    if (pd_e & 0x80) {                                    // 2 MiB page
        PAddr page_pa = pd_e & 0x000FFFFFFFE00000ULL;
        return page_pa | (va & 0x1FFFFF);
    }
    PAddr pt_pa = pd_e & 0x000FFFFFFFFFF000ULL;

    u64 pte = read_pte(pt_pa + pt_idx * 8);
    if (!(pte & 0x1)) return 0;
    PAddr page_pa = pte & 0x000FFFFFFFFFF000ULL;
    return page_pa | (va & 0xFFF);
}
```

## When the DTB isn't validated

The engine's `KernelContext` includes a `dtb_validated` flag. When
false (the DTB resolver couldn't find a PGD that walks back to the
banner — see [Symbol resolution](../features/symbol-resolution.md)),
the `dtb` field still holds the best guess, but using
`eng->kernel_pt()` may return garbage.

Code that needs kernel-VA reads (`/sys/banner.txt`, `/sys/dmesg`,
etc.) checks `dtb_validated` first:

```cpp
if (!eng.kernel().dtb_validated) {
    return ByteBuf{"; DTB unvalidated; kernel-VA reads disabled"};
}
```

User-VA reads (per-process `proc.dmp`) are unaffected — they use the
process's own PGD from `task->mm->pgd`, which is always reachable via
the direct map.

## Future: arm64

When we add arm64 support:

- New file: `src/arch/arm64/paging.cpp`
- 4-level walker, different bit layout (TTBR0/TTBR1 split, different
  PTE flag positions)
- Same `PageTable` interface — the `Engine` doesn't need to change
- A small arch dispatch in `engine.cpp` based on the dump's detected
  architecture (TBD: detect arm64 dumps via banner string)

## Performance numbers

On the bundled test dump (AVML, 2 GB max PA):

| Operation | Speed |
|---|---|
| Single VA → PA translation (cache cold) | ~50 µs (4 AVML decompresses) |
| Single VA → PA translation (cache warm) | < 100 ns |
| Sequential 4 KiB read (warm) | ~1 µs |
| Random 4 KiB read (cold) | ~50 µs (4 page-table reads) |
| Random 4 KiB read (warm — same PTE region) | ~5 µs (1 leaf-page miss) |

## Reference

- Intel manual Vol 3: `Intel® 64 and IA-32 Architectures Software Developer's
  Manual, Vol 3A, Chapter 4: Paging`
- Linux source: `arch/x86/include/asm/pgtable_*.h`,
  `arch/x86/mm/init_64.c`
- Volatility 3: `volatility3/framework/layers/intel.py` (Vol3's
  equivalent walker)
