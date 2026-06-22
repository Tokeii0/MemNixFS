# Code structure

A file-by-file map of the source tree. Use this when navigating the
codebase or planning where a new feature lives.

## Top-level

```
/
├── CMakeLists.txt          Root build file. Declares lmpfs_core (static lib)
│                           + memnixfs (executable). Options:
│                             LMPFS_BUILD_MOUNT_WINFSP   (default ON — the
│                                                         WinFsp mount IS the
│                                                         project's primary UX)
│                             LMPFS_BUILD_TESTS          (default OFF)
├── CMakePresets.json       MSVC x64 + vcpkg preset
├── vcpkg.json              snappy + liblzma + nlohmann-json + fmt + yara
├── README.md               High-level project README
├── docs/                   This wiki
├── tools/
│   └── fetch_symbols.sh    Multi-distro ISF generation script
└── src/                    All C++ source
```

## `src/core/` — Primitives

```
core/
├── types.h          u8/u16/u32/u64, i32/i64, VAddr/PAddr, ByteBuf,
│                    page-size constants
├── error.h          throw_error(), Error exception
├── log.h            log::info/debug/trace/warn/error, set_level()
├── log.cpp
└── stream.h         StreamReader interface — byte-range producer for
                     huge files (proc.dmp, phys.raw)
```

No external dependencies. Header-only-ish.

## `src/io/` — Memory source

```
io/
├── memory_source.h          MemorySource interface; open_best_memory_source()
├── file_memory_source.cpp   fopen/fread backend
└── mmap_memory_source.cpp   Windows CreateFileMapping + MapViewOfFile
                             (~833 MB/s on the test dump)
```

## `src/formats/` — Physical layer

```
formats/
├── physical_layer.h         PhysicalLayer interface (read/max_address/format_name)
├── format_factory.h
├── format_factory.cpp       Magic-based detection, picks raw/lime/avml/kdump
├── raw_format.cpp           1:1 identity mapping
├── lime_format.cpp          LiME range-headers
├── avml_format.cpp          AVML + Snappy frame decompression
├── kdump_format.cpp         ELF64 ET_CORE — PT_LOAD → PA map, PT_NOTE → VMCOREINFO
└── phys_raw_stream.h        /mem/phys.raw producer (StreamReader)
```

## `src/symbols/` — Symbol resolver

```
symbols/
├── isf_symbols.h            IsfSymbols class (types_, symbols_)
├── isf_symbols.cpp          JSON parser, anonymous-union flattener
├── xz_decompress.h          liblzma wrapper
├── xz_decompress.cpp
├── symbol_resolver.h        SymbolResolveOptions/Result
├── symbol_resolver.cpp      The 6-step resolution chain. A types-only (0-symbol)
│                            cached ISF is treated as a fallback, not a final
│                            answer — the chain keeps trying symbol-rich sources
│                            (HTTP mirror, --auto-fetch) first and only falls back
│                            to the types-only cache if they all miss.
├── symbol_cache_http.h
├── symbol_cache_http.cpp    WinHTTP fetch from community mirrors
├── btf_to_isf.h
├── btf_to_isf.cpp           BTF parser + ISF emitter + anon flattener
├── kallsyms.h
└── kallsyms.cpp             kallsyms signature scan + parser
```

This is the biggest single subsystem (~3,000 lines).

## `src/arch/x86_64/` — Page-table walker

```
arch/x86_64/
├── paging.h
├── paging.cpp               4-level walker, 2 MiB + 1 GiB page support
├── page_cache.h
└── page_cache.cpp           Per-process LRU page cache
```

When we add arm64: `src/arch/arm64/paging.{h,cpp}`. The interface
(`PageTable::read(VAddr, void*, size_t)`) is arch-agnostic.

## `src/os/linux/` — Linux kernel knowledge

```
os/linux/
├── kernel_resolver.h        KernelContext (init_task_pa/va, kaslr_*,
│                            direct_map_base, dtb, dtb_validated, banner)
├── kernel_resolver.cpp      Swapper signature scan, direct map derivation
├── dtb_resolver.h
├── dtb_resolver.cpp         3-strategy DTB scan with banner validation
├── banner_scan.h
├── banner_scan.cpp          "Linux version " string search, kernel release
│                            parsing, distro detection
├── btf_probe.h
├── btf_probe.cpp            Find BTF blobs in physical memory
├── process.h                Process struct
├── process_list.cpp         Task list walking via direct map
├── vma.h
├── vma.cpp                  Maple tree walker (≥ 6.1), VMA enumeration,
│                            user PGD resolution
├── elf_core.h
├── elf_core.cpp             ELF64 core dump writer
├── elf_core_stream.h
├── elf_core_stream.cpp      Streaming variant (no full materialisation)
├── task_files.h
├── task_files.cpp           Generators for /proc/<pid>/{cmdline,environ,
│                            status,stat,statm,limits,exe,cwd,root,
│                            maps,capabilities,loginuid,oom_score_adj}
├── kva_reader.h             Multi-strategy kernel-VA reader (direct-map /
├── kva_reader.cpp           image-shift / vmalloc-via-PGD with init_mm.pgd
│                            fallback). Used by every kernel-data walker.
├── dentry_path.h            dentry → absolute global path, with mount-point
├── dentry_path.cpp          crossing. Shared by fdtable + pagecache.
├── mountinfo.h              Walk init_task.nsproxy.mnt_ns; compose global
├── mountinfo.cpp            paths for every mount. /sys/mountinfo + the
│                            sb→vfsmount map needed by pagecache.
├── pagecache.h              Three-tier inode enumeration: (1) the global
├── pagecache.cpp            inode_hashtable (symbol-rich — needs the kallsyms
│                            anchor); (2) a super_blocks → s_inodes walk; and
│                            (3) a symbol-free fallback used on BTF-only ISFs —
│                            a per-process fd-table walk plus a dcache
│                            `d_children` tree walk seeded from each open file's
│                            `vfsmount.mnt_root`. Then walk each
│                            i_data.i_pages xarray and reassemble cached pages →
│                            file content. Powers /fs/ and /files/by-ino/.
├── netstat.h                TCP+UDP socket enumeration via tcp_hashinfo /
├── netstat.cpp              udp_table. Network interfaces via init_net.
│                            dev_base_head + in_device.ifa_list. Powers
│                            /sys/net/* and the socket-cross-link in
│                            /proc/<pid>/fd_table.txt.
├── findevil.h               Threat-hunt heuristics: malfind (anon-exec VMAs),
├── findevil.cpp             psscan (phys task_struct scan with cross-validation),
│                            hidden_modules (kallsyms-vs-modules diff). Powers
│                            /sys/findevil/* and /proc/<pid>/malfind.txt.
├── check_syscall.h          sys_call_table integrity check via kallsyms:
├── check_syscall.cpp        every entry validated against kernel-text bounds
│                            and handler-name conventions. Powers
│                            /sys/findevil/check_syscall.txt.
├── integrity_checks.h       Kernel function-pointer-table audits sharing one
├── integrity_checks.cpp     classify_ptr() helper. Powers /sys/findevil/
│                            {tty_check, keyboard_notifiers,        ← v0.9
│                             check_idt, check_afinfo,
│                             check_creds, check_modules}.txt.      ← v0.13
├── ebpf.h                   Walk `prog_idr` xarray → every loaded bpf_prog.
├── ebpf.cpp                 Powers /sys/findevil/ebpf.txt.          ← v0.14
├── entropy.h                Shannon-entropy scan over user-mode EXEC VMAs.
├── entropy.cpp              Powers /proc/<pid>/entropy.txt and
│                            /sys/findevil/entropy.txt.              ← v0.14
├── csv_export.h             RFC 4180 CSV emitters for highest-value plugins.
├── csv_export.cpp           Powers *.csv siblings under /sys/{processes,
│                            net,findevil}/.                          ← v0.15
├── tracing.h                kprobe_table walker + kprobe handler audit.
├── tracing.cpp              Powers /sys/findevil/kprobes.txt.         ← v0.16
├── kern_va_stream.h         128 TiB sparse view of the canonical kernel half
├── kern_va_stream.cpp       (`/mem/kern_va.raw`). Per-page kva_read with
│                            zero-fill on miss; opens the door to running
│                            HxD / FTK on kernel structs by VA.          ← v0.18
├── v2p_misc.h               Path-encoded virt2phys / phys2virt translators
├── v2p_misc.cpp             (`/misc/virt2phys/<hex-va>`, `/misc/phys2virt/<hex-pa>`).
│                            Dynamic-directory pattern via DirNode::find() —
│                            no writable file, no per-handle state.       ← v0.19
├── av_edr.h                 AV/EDR fingerprinting via process + module
├── av_edr.cpp               substring-match against a 50-pattern signature
│                            table. Powers /sys/findevil/av_edr.txt.      ← v0.20
├── json_export.h            JSON renderings of high-value plugins (sibling
├── json_export.cpp          of csv_export). Powers *.json under
│                            /sys/{processes,net,findevil}/.              ← v0.20
├── forensic_snapshot.h      One-stop dump-triage report (env + processes +
├── forensic_snapshot.cpp    network + threat-hunt + AV/EDR). Powers
│                            /forensic/snapshot.{txt,json}.               ← v0.20
├── strings_search.h         Printable-ASCII extractor + IOC scanner (URL,
├── strings_search.cpp       IPv4, email, JWT, AWS-key) over every user
│                            VMA. Powers /proc/<pid>/strings.txt +
│                            /search/iocs.txt.                            ← v0.21
├── task_extras.h            Per-pid file generators that need VMA + dentry
├── task_extras.cpp          infra (gen_libs + gen_ptrace). Powers
│                            /proc/<pid>/libs.txt + ptrace.txt.           ← v0.21
├── yara_search.h            libyara wrapper + built-in default ruleset.
├── yara_search.cpp          Powers /search/yara.txt + /proc/<pid>/yara.txt
│                            and (v0.26) per-rule /search/yara/<rule>.txt.
│                            Built only when LMPFS_BUILD_YARA=ON.          ← v0.22
├── tracepoints.h            Kernel-tracepoint enumeration. Walks every
├── tracepoints.cpp          `__tracepoint_*` kallsyms symbol, reads the
│                            tracepoint's funcs array, audits each handler.
│                            Powers /sys/findevil/tracepoints.txt.         ← v0.26
├── sysinfo.h                /sys/hostname (init_uts_ns), /sys/uptime
├── sysinfo.cpp              (jiffies_64), /sys/mounts (/proc/mounts shape),
│                            + v0.28: /sys/cpuinfo (boot_cpu_data),
│                            /sys/meminfo (totalram_pages), /sys/iomem
│                            (iomem_resource tree), /sys/boottime.
├── sysinfo_more.cpp         /sys/dns.txt (resolv.conf reads via /fs/),
│                            /sys/pidhashtable (init_pid_ns anchor),
│                            /sys/net/arp (arp_tbl anchor),
│                            /sys/net/unix (per-process recipe).      ← v0.28
├── users.h                  /sys/users.txt — UID → name table from
├── users.cpp                /fs/etc/passwd page-cache read, joined with
│                            live task uid distribution.                    ← v0.27
├── timeline.h               Merges timestamps across dmesg / shell_history.txt /
├── timeline.cpp             eBPF load_time into one forensic timeline.
│                            Powers /forensic/timeline.{txt,csv}.      ← v0.17
├── pscallstack.h            Per-task kernel-stack walker. Reads task.stack +
├── pscallstack.cpp          thread.sp, scans 16 KiB stack for kernel-text
│                            values, resolves each via kallsyms. Powers
│                            /proc/<pid>/kstack.txt.
├── threads.h                Per-leader thread enumeration via
├── threads.cpp              signal->thread_head. Powers
│                            /proc/<pid>/threads.txt and
│                            /sys/processes/threads.txt.
├── process_views.h          ps -ef / pstree / ps aux text renderings of the
├── process_views.cpp        canonical process list (eng.processes()). Powers
│                            /sys/processes/*.
├── dmesg.h
├── dmesg.cpp                printk_ringbuffer (prb) parser for /sys/dmesg.
├── modules.h
├── modules.cpp              `modules` list walk → loaded-module enumeration.
├── fdtable.h
├── fdtable.cpp              task->files->fdt->fd[] for /proc/<pid>/fd_table.txt.
├── bash_history.h
└── bash_history.cpp         HIST_ENTRY heap scan feeding /proc/<bash-pid>/shell_history.txt.
```

This is where the bulk of "what to read from kernel structures" logic
lives. Adding a new `/proc/<pid>/<file>` is usually:
1. Add a generator function in `task_files.cpp`
2. Register the file node in `proc_module.cpp`

## `src/vfs/` — Virtual filesystem tree

```
vfs/
├── vfs.h            Node, DirNode, LazyFileNode, SizedLazyFileNode, StreamFileNode.
│                    Nodes carry a `FileCost` cost tag; `Node::size_hint()` gives a
│                    cheap, non-producing size for directory listings (distinct
│                    from the authoritative `size()` that may run the producer).
│                    `LazyFileNode` caches its content under a per-node mutex and
│                    exposes `warm()` (pre-run the producer off the read path).
├── vfs.cpp
├── proc_module.cpp  build_proc_tree() — builds /proc/<pid>-<comm>/ subtree
├── sys_module.h
├── sys_module.cpp   build_sys_tree() — builds /sys/{banner.txt,dtb.txt,
│                    kallsyms,btf.txt,dmesg,modules/,pagecache/,mountinfo}
├── forensic_warmer.h
└── forensic_warmer.cpp  Background pre-warmer for forensic mode — walks the VFS
                     tree and runs expensive-but-small file producers on a thread
                     pool so they're cached before the user browses (see
                     docs/features/forensic-mode.md).
```

The `/fs/` (reconstructed root filesystem) and `/files/by-ino/` trees are
assembled directly in `app/engine.cpp` from `enumerate_cached_inodes()`'s
output — they're too tightly coupled to the inode enumeration to live in
their own vfs module.

## `src/cli/` — CLI entry

```
cli/
└── main.cpp         argv parsing, dispatch to list/tree/export/mount/kallsyms
```

## `src/api/` — Public C API

```
api/
├── lmpfs.h               Native `lmpfs_*` C ABI. extern "C",
│                         __declspec exports gated on LMPFS_API_BUILDING.
│                         Opaque handle.                          ← v0.23
├── lmpfs.cpp             Implementation. Per-handle mutex; translates
│                         std::exception → thread-local last_error.
├── vmmdll_compat.h       MemProcFS-shaped `VMMDLL_*` surface exported
│                         from the SAME memnixfs.dll.             ← v0.24
├── vmmdll_compat.cpp     Implementation in terms of lmpfs_* — every
│                         VMMDLL_ entry point translates one-or-two-step
│                         to an lmpfs_ call. Argv parser is lenient
│                         (silently ignores unrecognised flags so
│                         script compatibility doesn't depend on
│                         flag-list exact match).
└── lmpfs_plugin.h        Plugin SDK ABI. Third-party DLL drop-ins
                          export `lmpfs_plugin_init`, call back into
                          `lmpfs_plugin_add_file` to register paths
                          under `/plugins/<plugin-name>/`.            ← v0.25
```

The DLL serves two audiences from one binary:
* native C/C++ (and any C-FFI consumer) via `lmpfs_*`
* MemProcFS-ecosystem code via `VMMDLL_*`

## `src/mount/` — Mount backends

```
mount/
├── winfsp_mount.cpp Windows-only adapter. Stateless callbacks pattern.
│                    Built by default (LMPFS_BUILD_MOUNT_WINFSP=ON).
│                    Read callback is defensive: caps Length to (size - Offset)
│                    and zero-fills any producer underdelivery, matching
│                    sparse-file semantics and preventing "stream read error"
│                    in HxD when reading the page-cache reconstruction.
└── fuse_mount.cpp   Linux libfuse3 adapter (LMPFS_BUILD_MOUNT_FUSE=ON).
                     Same VFS tree, exposed via FUSE on Linux hosts.
```

## `src/app/` — Top-level wiring

```
app/
├── engine.h         Engine class — owns every layer, exposes vfs_root().
│                    Its last-declared member is a `ForensicWarmer`, so the
│                    warmer's destructor joins its worker threads before the
│                    captured engine state is torn down. Started only when
│                    `Options::forensic` is set.
└── engine.cpp       Engine::create() — assembles layers in order
```

This is the *only* file where concrete layers are wired together.
Everything else only knows about the interfaces.

## File-count summary

| Subsystem | File count | Approx. LOC |
|---|---|---|
| `core/` | 5 | ~200 |
| `io/` | 3 | ~300 |
| `formats/` | 8 | ~900 |
| `symbols/` | 11 | ~3,000 |
| `arch/x86_64/` | 4 | ~600 |
| `os/linux/` | 75 | ~12,900 |
| `api/`      | 5  | ~1,000  |
| `vfs/` | 7 | ~750 |
| `cli/` | 1 | ~250 |
| `mount/` | 2 | ~900 |
| `app/` | 2 | ~250 |
| **Total** | **97** | **~15,500** |

Plus `tools/fetch_symbols.sh` (~300 lines of bash) and docs.

## Dependency direction (strict)

```
app/engine ─→ cli, mount
            ↓
            vfs
            ↓
            os/linux ─→ arch/x86_64
                     ↓
                     symbols ─→ formats ─→ io ─→ core
```

A lower layer never includes a higher one. `core/` is the leaf
(included by everyone, depends on no one).

## How to add a new feature

tl;dr:

1. Decide which layer it belongs to (usually `os/linux/` for new
   forensic data, or `vfs/` for new files).
2. Add the source files.
3. Wire into `CMakeLists.txt`'s `lmpfs_core` source list.
4. If user-visible: add a CLI flag or a VFS node (in `proc_module.cpp`
   or `sys_module.cpp`).
5. Document it: add a page under `docs/features/`.
