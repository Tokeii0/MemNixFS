# Architecture

MemNixFS is a strictly **layered** engine. Each layer depends only on the
one directly below it, and each layer exposes a small, swappable interface.
This is intentional — it means a different physical-memory backend
(network, raw device), a new architecture (arm64), or a different mount
backend (FUSE on Linux) can be added without touching unrelated code.

## Layer diagram

```
┌─────────────────────────────────────────────────┐
│  CLI / Mount backends (WinFsp, FUSE)    │   src/cli, src/mount
├─────────────────────────────────────────────────┤
│  VFS tree + modules (proc/, sys/, mem/)         │   src/vfs
├─────────────────────────────────────────────────┤
│  Process / Task enumeration (Linux)             │   src/os/linux
├─────────────────────────────────────────────────┤
│  Kernel resolver (KASLR, init_task, DTB)        │   src/os/linux
├─────────────────────────────────────────────────┤
│  Virtual memory (x86_64 page walker + LRU)      │   src/arch/x86_64
├─────────────────────────────────────────────────┤
│  Symbol resolver (ISF / BTF→ISF / kallsyms)     │   src/symbols
├─────────────────────────────────────────────────┤
│  Physical memory (Raw / LiME / AVML+Snappy)     │   src/formats
├─────────────────────────────────────────────────┤
│  Memory source (file-backed / mmap-backed)      │   src/io
└─────────────────────────────────────────────────┘
```

## What each layer does

### `src/io` — Memory source
The lowest layer. `MemorySource` is a `(offset, len) → bytes` interface.
Implementations:
- `file_memory_source.cpp` — generic `fopen`/`fread`/`fseek`.
- `mmap_memory_source.cpp` — Windows `CreateFileMapping` + `MapViewOfFile`.
  Selected by `open_best_memory_source()` when the OS supports it.
  Measured 833 MB/s on the test dump (vs ~80 MB/s for `fread`).

### `src/formats` — Physical layer
Translates a dump-format-specific byte stream into uniform "give me byte
range `[pa, pa+len)` of physical memory" queries. `PhysicalLayer` is the
interface; implementations include:
- `raw_format.cpp` — 1:1 (PA == file offset)
- `lime_format.cpp` — LiME header parsing
- `avml_format.cpp` — AVML chunk index + per-chunk Snappy decompression

`format_factory.cpp` peeks the first few bytes and picks the right one.

### `src/symbols` — Symbol resolver
Multi-stage chain for finding (or synthesising) a Volatility-3 ISF that
matches the dump's kernel. See [Symbol resolution](features/symbol-resolution.md)
for the full chain. Key subsystems:
- `isf_symbols.{h,cpp}` — load `.json[.xz]` ISF, flatten anonymous unions
- `xz_decompress.{h,cpp}` — liblzma wrapper
- `btf_to_isf.{h,cpp}` — BTF parser + ISF emitter
- `kallsyms.{h,cpp}` — kallsyms extractor
- `symbol_cache_http.{h,cpp}` — WinHTTP fetch from community mirrors
- `symbol_resolver.{h,cpp}` — orchestrates the 6-step chain

### `src/arch/x86_64` — Page-table walker
- `paging.{h,cpp}` — 4-level PGD walker (PML4 → PDPT → PD → PT), with
  2 MiB and 1 GiB page support
- `page_cache.{h,cpp}` — LRU cache of decoded user-PGD pages (16 MiB
  default). Cuts repeat-read cost from "AVML decompress + 4 PA reads"
  to one `memcpy`.

### `src/os/linux` — Linux kernel knowledge
This is where Linux-specific algorithm lives.
- `kernel_resolver.{h,cpp}` — find `init_task` PA (swapper signature
  scan), derive KASLR shift, find and validate `direct_map_base`
- `dtb_resolver.{h,cpp}` — multi-strategy DTB scan (banner-anchored,
  init_task-anchored, brute-force PGD scan) with banner walk-back
  validation
- `banner_scan.{h,cpp}` — finds `"Linux version "` strings in physical
  memory regardless of whether we have any ISF symbols
- `btf_probe.{h,cpp}` — finds BTF blobs in physical memory
- `process.h, process_list.cpp` — task list walking
- `vma.{h,cpp}` — Maple tree walker (kernels ≥ 6.1), VMA enumeration,
  per-process PGD resolution
- `elf_core.{h,cpp}, elf_core_stream.{h,cpp}` — ELF64 core dump writer
  for `/proc/<pid>/proc.dmp`
- `task_files.{h,cpp}` — generators for each per-pid file

### `src/vfs` — Virtual filesystem tree
- `vfs.{h,cpp}` — `Node`, `DirNode`, `LazyFileNode`, `StreamFileNode`
- `proc_module.cpp` — builds `/proc/<pid>/...` subtree
- `sys_module.{h,cpp}` — builds `/sys/banner.txt`, `/sys/dtb.txt`,
  `/sys/btf.txt`, `/sys/kallsyms`

### `src/cli` — Command-line entry
- `main.cpp` — argument parsing, dispatches to `list` / `tree` /
  `export` / `mount` / `kallsyms`

### `src/mount` — Mount backends
- `winfsp_mount.cpp` — WinFsp adapter. Stateless callbacks (raw `Node*`
  through `fctx`, no per-Open allocation), delay-loaded `winfsp-x64.dll`
- `fuse_mount.cpp` — FUSE adapter. Read-only callbacks reuse the
  same VFS `Node` interface and mirror WinFsp sparse zero-fill semantics.

### `src/app` — Top-level wiring
- `engine.{h,cpp}` — `Engine::create()` assembles the layers in order,
  exposes `processes()`, `kernel()`, `vfs_root()`, `kallsyms()`

## Data flow: opening a dump

```
1. open_best_memory_source(dump_path)
   → mmap'd MemorySource

2. open_physical_layer(memory_source)
   → AVML / LiME / Raw PhysicalLayer (magic-detected)

3. resolve_symbols(phys, options)
   → tries user file → cache → BTF+kallsyms in dump → vmlinux → HTTP → auto-fetch
   → returns path to ISF JSON

4. IsfSymbols::load(isf_path)
   → parsed types + symbols

5. resolve_kernel(phys, isf)
   → init_task PA (swapper scan)
   → KASLR shift (from init_task or banner)
   → direct_map_base (from init_task.tasks.next, validated against the
     first task's pid/tgid/comm and list back-pointer)
   → DTB (3-strategy scan + banner round-trip validation)

6. PageTable(phys, kctx.dtb)
   → kernel-VA reader, only used when dtb_validated

7. list_processes(phys, pt, isf, kctx)
   → walks task list via direct map (no DTB needed)

8. extract_kallsyms(phys)
   → 100k+ symbol name+VA pairs

9. build_proc_tree(processes, phys, pt, isf, kctx)
   build_sys_tree(engine)
   → VFS root node, populated lazily
```

Then the CLI runs `list` / `tree` / `export` / `mount` against `eng->vfs_root()`.

## Design principles

### Each layer is replaceable
A `MemorySource` could be backed by a network connection, an arbitrary
file, or live `/proc/kcore`. A `PhysicalLayer` could be a `kdump`
reader or QEMU `.vmem`. A page walker could be arm64. The Engine
class is the **only** place that wires concrete types together; the
layers themselves only know about the interfaces below them.

### Lazy + streaming
Big files (`proc.dmp` for an 8 GB process, `phys.raw` for a 16 GB dump)
are NOT materialised. `StreamFileNode` wraps a producer that takes
`(offset, len) → bytes`, and the VFS / mount backends serve byte-ranges
on demand. A process listing the tree never touches the actual data.

### Stateless mount backends
Per-Open allocation + per-Close `delete` is a classic source of bugs in
filesystem adapters because callbacks can outlive individual opens in
surprising ways. MemNixFS follows MemProcFS's pattern: pass the raw `Node*`
(lives in the VFS tree for the mount lifetime), and keep close/release paths
as no-op cleanup where possible. The FUSE backend starts single-threaded until
all lazy VFS producers are audited for multi-threaded mount dispatch.

### Fail soft, log loud
When something can't be resolved (DTB scan finds no validated PGD,
kallsyms `relative_base` is in a dump gap, BTF is parser-rejected),
the engine logs the failure and degrades to whatever still works.
Process listing keeps working even when kernel-VA reads don't. Only
explicit user errors (wrong CLI flag, file not found) throw.

### Cite your references
Every non-trivial source file's header comment cites:
- The MemProcFS module it parallels (for UX / file-format inspiration)
- The Volatility 3 plugin it mirrors (for the Linux algorithm)
- The kernel source file where the algorithm comes from

This is how we keep correctness traceable.
