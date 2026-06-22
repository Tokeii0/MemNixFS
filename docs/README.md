# MemNixFS — Documentation

This is the project's documentation. Read top-to-bottom for a guided tour, or
jump to whatever you need.

---

## Getting started

| Document | What it covers |
|---|---|
| [Overview](overview.md) | What MemNixFS is, who it's for, key value |
| [Architecture](architecture.md) | How the layers fit together |
| [Building from source](building.md) | Windows + MSVC + vcpkg recipe |
| [CLI reference](cli-reference.md) | Every flag and command |

---

## Features (currently implemented)

| Page | Topic |
|---|---|
| [Dump formats](features/dump-formats.md) | AVML / LiME / raw readers |
| [Symbol resolution](features/symbol-resolution.md) | The 6-step ISF chain |
| [BTF → ISF](features/btf-to-isf.md) | Offline ISF synthesis from `.BTF` |
| [kallsyms](features/kallsyms.md) | Kernel symbol table extraction |
| [Process enumeration](features/process-enumeration.md) | Task list walking |
| [VMAs & memory](features/vma-and-memory.md) | Maple tree + per-process PGD + ELF-core |
| [/proc/&lt;pid&gt;/ files](features/proc-tree.md) | Every per-process file |
| [/sys/ files](features/sys-tree.md) | System-wide views (banner, dtb, kallsyms, btf, dmesg, modules, pagecache). Use `/sys/` for system-wide views. |
| **[Page-cache + file recovery](features/pagecache.md)** | Every cached inode + byte-exact file content recovery |
| **[Network state](features/network.md)** | TCP/UDP sockets, interfaces, per-process socket cross-link |
| **[Process views](features/process-views.md)** | `ps`-style flat / tree / aux text renderings of the canonical list |
| **[Threat-hunt (findevil)](features/findevil.md)** | malfind + psscan + hidden_modules aggregated verdict |
| **[Forensic mode & performance](features/forensic-mode.md)** | Background preload of expensive+small files + cheap directory listing |
| **[Crash & journal evidence](features/crash-journal.md)** | Conservative crash / log / journald triage under `/sys/crash/` + `/sys/journal/` |
| [C API / programmable](features/c-api.md) | `memnixfs.dll` — native `lmpfs_*` C ABI + MemProcFS `VMMDLL_*` shim |
| [Live mount](features/mount.md) | Live filesystem mount via WinFsp or FUSE |

---

## Recipes & how-tos

| Page | Topic |
|---|---|
| [Offline workflows](recipes/offline-workflows.md) | How to work fully air-gapped |
| [Creating test dumps](recipes/creating-test-dumps.md) | AVML / LiME / QEMU `pmemsave` |
| **[Extract files from memory](recipes/extract-files-from-memory.md)** | Page-cache file recovery (no process needed!) |
| [Troubleshooting](recipes/troubleshooting.md) | Common errors and fixes |

---

## Internals (for contributors)

| Page | Topic |
|---|---|
| [Code structure](internals/code-structure.md) | File-by-file source-tree map |
| [ISF JSON format](internals/isf-format.md) | Volatility-3 ISF schema we read & emit |
| [kallsyms deep-dive](internals/kallsyms-deep-dive.md) | Bit-level layout, decode formulas |
| [x86_64 page walker](internals/x86_64-paging.md) | 4-level PGD, 2 MiB / 1 GiB pages |

---

## Project meta

| Page | Topic |
|---|---|
| [Glossary](glossary.md) | Terms (KASLR, DTB, BTF, ISF, …) |

---

