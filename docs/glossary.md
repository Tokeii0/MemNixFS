# Glossary

Terms used in MemNixFS and Linux memory forensics generally.

---

### AVML
**Azure Memory Loader.** A Microsoft-maintained tool for acquiring
Linux memory dumps. Produces `.lime.compressed` files (LiME format
wrapped in Snappy-framed compression). MemNixFS's
`src/formats/avml_format.cpp` reads them.

### BTF
**BPF Type Format.** A compact kernel type-information format
(`include/uapi/linux/btf.h`). Modern kernels built with
`CONFIG_DEBUG_INFO_BTF=y` embed ~3 MB of BTF in the `.BTF` ELF section,
which lands in any memory dump. MemNixFS parses it
([details](features/btf-to-isf.md)).

### canonical address
On x86_64, a virtual address whose bits 47..63 are all the same
(all 0 for user-space, all 1 for kernel-space). Non-canonical addresses
trigger a fault. MemNixFS's page walker rejects them.

### `comm`
The 16-character process name field in `task_struct` (limited to 15
chars + NUL). Set by `prctl(PR_SET_NAME)` or the basename of the
executable.

### CONFIG_KALLSYMS_BASE_RELATIVE
Kernel config option (default y since 4.6) that stores symbol
addresses as 32-bit offsets from a base, instead of full 64-bit
absolute addresses. Halves the size of `kallsyms_offsets`. MemNixFS's
kallsyms parser handles both encodings (currently only BASE_RELATIVE;
pre-4.6 is future work).

### CONFIG_KALLSYMS_ABSOLUTE_PERCPU
Sub-option of `CONFIG_KALLSYMS_BASE_RELATIVE` (default y) that handles
symbols outside the kernel image range (percpu vars, vsyscall, etc.)
by storing `-(absolute_VA + 1)` as the offset. Decoded by
`addr = relative_base - 1 - offset`.

### DFIR
**Digital Forensics + Incident Response.** The discipline this tool
serves. Memory forensics is one DFIR sub-discipline.

### direct map (physmap)
Kernel virtual address range where all physical RAM is mapped 1:1
(plus a per-arch offset). On x86_64 it lives somewhere near
`0xFFFF888000000000` (KASLR'd). MemNixFS derives the base from
`init_task.tasks.next` and uses it to translate kernel direct-map VAs
to PAs without a page-table walk.

### DTB
**Directory Table Base.** The physical address of the kernel's current
top-level page table (PGD on Linux, `swapper_pg_dir` or
`init_top_pgt` static, dynamic at runtime). Walking this PGD lets us
resolve kernel virtual addresses to physical. See
[Symbol resolution](features/symbol-resolution.md).

### `dwarf2json`
Volatility-3's tool that converts DWARF debug info (from vmlinux) to
the Volatility-3 ISF JSON format. We invoke it via
`tools/fetch_symbols.sh` when `--vmlinux` or `--auto-fetch` is used.

### ELF core
ELF64 file with `e_type = ET_CORE`. Used by Linux to save process
memory on crash (`coredump`), and by us to expose
`/proc/<pid>/proc.dmp`. Each `PT_LOAD` segment is one VMA.

### ISF
**Intermediate Symbol File.** Volatility 3's JSON format for kernel
symbol tables. We read (`isf_symbols.cpp`) and emit (`btf_to_isf.cpp`)
this format. [Format details](internals/isf-format.md).

### `init_task`
The kernel's first `task_struct`, representing the idle thread (PID 0,
`comm == "swapper/0"`). All other processes hang off its `tasks` list
in a circular doubly-linked list. MemNixFS finds it by scanning
physical memory for the "swapper/0" comm signature.

### `init_top_pgt` / `swapper_pg_dir`
The static (compile-time) name for the kernel's PGD. Visible in
ISFs as symbols. On modern x86_64 kernels, the runtime PGD is a
dynamically-allocated PGD whose PA isn't a symbol (kernel switches to
it during boot init). The DTB resolver's brute-force scan finds it.

### kallsyms
The kernel's compressed symbol table. Backs `/proc/kallsyms` on a
running system. Compiled into every kernel built with
`CONFIG_KALLSYMS=y` (default everywhere). MemNixFS extracts it from
the dump directly ([details](features/kallsyms.md)).

### KASLR
**Kernel Address Space Layout Randomization.** At boot, the kernel
shifts itself and the direct map by random 2-MiB-aligned offsets to
make exploits harder. MemNixFS derives the shift from `init_task`'s
discovered PA vs. its static (pre-KASLR) VA in the ISF.

### kdump
A kernel feature where, on panic, a reserved "crash kernel" boots and
dumps memory of the panicked kernel to disk. Produces a `vmcore` ELF
file (ELF64 `ET_CORE`). MemNixFS reads this format — auto-detected,
with `PT_LOAD` segments mapped to physical addresses and `PT_NOTE`
VMCOREINFO captured. See [dump-formats.md](features/dump-formats.md).

### LiME
**Linux Memory Extractor.** A kernel module for acquiring memory dumps
on a live Linux system. Produces uncompressed `.lime` files with a
simple range-header format. MemNixFS reads them via
`src/formats/lime_format.cpp`.

### linux_banner
A kernel global containing the string
`Linux version <release> (...) <build_info>`. Used for kernel version
ID, as the validation target for DTB walks (the banner string is at a
known offset from `_text`), and to compute KASLR shift via
banner-PA-vs-static-PA arithmetic.

### Maple tree
The B+-tree-of-pivots data structure that replaced rbtree+linked-list
for VMAs in Linux 6.1. Defined in `include/linux/maple_tree.h`.
MemNixFS walks it in `src/os/linux/vma.cpp`.

### MemProcFS
Ulf Frisk's [Windows memory forensics tool](https://github.com/ufrisk/MemProcFS)
that exposes a Windows memory dump as a virtual filesystem. MemNixFS
is the Linux equivalent.

### `mm_struct`
A process's memory descriptor. Contains the PGD root, VMA tree, exec
file pointer, args/env address ranges, etc. Reached via `task->mm`.
NULL for kernel threads (they share the kernel's address space).

### PGD / PDPT / PD / PT
The 4 levels of the x86_64 page-table hierarchy: Page Global
Directory → Page-Directory Pointer Table → Page Directory → Page
Table. Each level is a 4-KiB page of 512 8-byte entries.

### `pmemsave`
QEMU monitor command that writes the guest's physical memory to a
file. Produces a gap-free raw dump. The recommended way to make a
clean test dump for MemNixFS development.

### relative_base
For `CONFIG_KALLSYMS_BASE_RELATIVE=y` kernels: a u64 kernel VA
(typically `_text`) from which all kallsyms offsets are measured.
Stored in physical memory as `kallsyms_relative_base`.

### Snappy
Google's fast lossless compression algorithm. AVML uses framed Snappy
(`google/snappy` with `streaming-protocol`) to compress page chunks.

### task_struct
The Linux per-process control structure (`include/linux/sched.h`). Big
(~13 KB on a modern kernel). MemNixFS reads `pid`, `tgid`, `comm`,
`tasks`, `parent`/`real_parent`, `mm`, `cred`, and a few more fields.

### `vm_area_struct` (VMA)
A single contiguous memory mapping within a process. One per
`mmap()`-style mapping. Linked together in the maple tree (`mm_mt`).

### Volatility 3
[Open-source Python memory forensics framework](https://github.com/volatilityfoundation/volatility3).
MemNixFS borrows its Linux algorithms and uses its ISF symbol format.

### VMCOREINFO
An ELF-note in kdump dumps containing key kernel constants (DTB,
KASLR offset, struct field offsets). MemNixFS captures it from the
`PT_NOTE` segment when reading a kdump/vmcore; wiring those constants
into DTB resolution (which would make it trivial) is future work.

### WinFsp
[User-mode filesystem driver for Windows](https://winfsp.dev/). MemNixFS
links against it (delay-loaded) to provide the `mount` command.

### xz / LZMA
Compression format used for ISF files (`.json.xz`). MemNixFS reads and
writes via liblzma (`src/symbols/xz_decompress.cpp`).
