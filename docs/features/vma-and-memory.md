# VMAs & process memory

## Reading per-process memory

A process's virtual address space is described by:
- A list of **VMAs** (`vm_area_struct`) — one per contiguous mapped
  region (e.g. one for `.text`, one for `.rodata`, one for the heap,
  one per loaded shared library)
- A **page table** (`mm_struct.pgd`) rooted at a PA

MemNixFS reads both, producing:
- `/proc/<pid>/maps` (the VMA list in `/proc/PID/maps` text format)
- `/proc/<pid>/proc.dmp` (an ELF64 core dump of the process's mapped memory)
- `/proc/<pid>/memmap.txt` (a human-readable VMA list with sizes / files)

## Walking the VMA tree

### Pre-6.1 (legacy rbtree)
Older kernels keep VMAs in `mm_struct.mmap` (a singly-linked list) and
`mm_struct.mm_rb` (a red-black tree). Walking is trivial: follow
`vm_next` pointers.

### 6.1+ (Maple tree)
Linux 6.1 introduced the **Maple tree** (`maple_tree.h`) as the new
VMA storage, replacing both `mmap` and `mm_rb`. The tree root is
`mm_struct.mm_mt`.

A maple tree is a B+ tree of pivots; each leaf node holds entries
indexed by virtual address. Walking:

```cpp
// src/os/linux/vma.cpp
void walk_maple_tree(mm_pgd_pa, mm_va, callback);
```

The implementation walks via the kernel direct map (so it doesn't
require a validated DTB):

1. Read `mm->mm_mt.ma_root` (the root node pointer).
2. Distinguish leaf vs internal node by low-bit tags (per `MA_ROOT`,
   `MA_NODE_TYPE_*` definitions in `linux/maple_tree.h`).
3. Recursively traverse, yielding each `vm_area_struct *` whose pivot
   range is non-zero.

Maple-tree node layout is kernel-internal but stable since 6.1; we
read the right fields by ISF lookups (`maple_tree`, `maple_node`,
`maple_arange_64`).

## VMA fields we read

| Field | Used for |
|---|---|
| `vm_start`, `vm_end` | Address range (PA-relative for displays) |
| `vm_flags` | r/w/x/private/shared permissions |
| `vm_pgoff` | Offset within the mapped file (for `/proc/PID/maps`) |
| `vm_file` | Pointer to `file` struct (resolved to a path) |
| `anon_name` | Anonymous-region label (in newer kernels) |

For `vm_file`, we walk:
```
vm_file → f_path.dentry → d_iname (if simple) or chained d_parent
```
…to produce the mounted path as it appears in `/proc/PID/maps`.

## Per-process page-table walking

To read a process's memory (for `proc.dmp`), we need to translate user
virtual addresses to physical. This uses the per-process PGD:

```cpp
PAddr user_pgd_pa = read_pod(task.mm + offset_of(mm_struct, pgd));
x86_64::PageTable user_pt(phys, user_pgd_pa);
ByteBuf bytes = user_pt.read(va, n);
```

The 4-level walker (`src/arch/x86_64/paging.cpp`) handles:
- 4 KiB pages (PML4 → PDPT → PD → PT → page)
- 2 MiB pages (PML4 → PDPT → PD with PSE flag → page)
- 1 GiB pages (PML4 → PDPT with PSE flag → page)
- Non-present pages (returns zero bytes)
- Reserved bits / bad entries (returns zero bytes)

## LRU page cache

Walking a PGD for every read would be slow (4 page-table walks per
byte read). `src/arch/x86_64/page_cache.cpp` caches decoded user-PGD
pages:

- Per-process: each `Process` gets its own `UserPageCache`
- Eviction: LRU
- Default size: 16 MiB per process
- Hit rate on `proc.dmp` reads: > 99% (sequential access patterns)

Measured: cuts AVML-decompress-and-walk cost from ~5 ms per page to
< 1 μs per byte for cached pages.

## ELF64 core dump (`proc.dmp`)

`src/os/linux/elf_core_stream.cpp` produces a valid ELF64 core file
on the fly:

- `e_type = ET_CORE`
- One `PT_LOAD` segment per readable VMA
- Each segment's data is page-aligned and read via the user PGD
- File offsets computed so consumers (gdb, readelf, objdump) can
  parse the whole file

### Streaming vs materialised
The streaming variant (`elf_core_stream.{h,cpp}`) produces byte ranges
on demand. A `cat proc.dmp` walks all VMAs linearly; an `xxd -s 0x100000`
seeks and reads just that region. **No materialisation in RAM.**

This means a 4 GB Firefox process's `proc.dmp` doesn't allocate 4 GB
of memory — it streams as the consumer reads it.

### Validated against vol3
On the test dump we cross-checked bash's first VMA (192 KB ELF header
+ rodata) and its 956 KB `.text` segment byte-for-byte against
`vol linux.elfs.Elfs --pid 4849 --dump`. Same SHA-256, zero-byte diff.
The 31 `PT_LOAD` entries we emit match the 31 VMAs `vol linux.proc.Maps`
reports.

## Defaults and caps

| Setting | Default | Where |
|---|---|---|
| ELF-core max bytes per process | 256 MiB | `src/os/linux/elf_core.h` |
| User PGD page cache | 16 MiB / process | `src/arch/x86_64/page_cache.h` |
| Streaming chunk size | 64 KiB | `src/cli/main.cpp` export loop |

The 256 MiB cap exists so that `mount` / `export` complete inside
WinFsp's IRP-timeout window for huge processes. The first 256 MiB of
readable VMAs are dumped; this typically includes heap + main binary
+ major shared libraries.

To remove the cap: edit `kDefaultElfCoreMaxBytes` in
`elf_core.h`. Future work: do streaming reads end-to-end so the cap
becomes unnecessary.

## Reference

- Linux source: `include/linux/maple_tree.h`, `mm/mmap.c`, `fs/proc/task_mmu.c`
- Volatility 3 plugins: `proc.Maps`, `elfs.Elfs`, `library_list.py`
- MemProcFS: `vmm/modules/m_proc_memmap.c`, `m_proc_minidump.c`
