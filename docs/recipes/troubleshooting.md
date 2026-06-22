# Troubleshooting

Common errors and fixes, in rough order of frequency.

## "Unknown command: mount"

You built the binary without a mount backend. On Windows, enable WinFsp. On
Linux, enable FUSE.

```powershell
# Reconfigure the existing build dir
cmake -B build/msvc-x64 -DLMPFS_BUILD_MOUNT_WINFSP=ON
cmake --build build/msvc-x64 --config Release --target memnixfs
```

```bash
cmake -S . -B build/linux-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLMPFS_BUILD_MOUNT_FUSE=ON \
  -DLMPFS_BUILD_MOUNT_WINFSP=OFF
cmake --build build/linux-release --target memnixfs
```

If CMake then hard-fails with `WinFsp SDK not found …`, install WinFsp
from <https://winfsp.dev/> (free, ~5 MB) and re-run.

## "WinFsp SDK not found"

CMake found no WinFsp headers/import library at the expected SDK paths:

```powershell
Test-Path "C:\Program Files (x86)\WinFsp\inc\winfsp\winfsp.h"
Test-Path "C:\Program Files (x86)\WinFsp\lib\winfsp-x64.lib"
```

If those are `False` but `C:\Program Files (x86)\WinFsp\bin\winfsp-x64.dll`
exists, only the runtime is installed. Reinstall WinFsp with the developer
SDK components, then reconfigure with `LMPFS_BUILD_MOUNT_WINFSP=ON`.

## "Stream read error" in HxD / FTK Imager / file viewer

A file appears in `M:\fs\…` with a correct size, but opening it in a
hex editor errors out mid-read.

This was a v0.3-pre bug: `recover_file` produced a buffer that could be
smaller than what `size()` reported (when not every page was cached),
and Windows treats partial reads inside the reported file size as
I/O failures. Fixed in v0.3 by:

1. `recover_file` now always allocates exactly `inode.i_size` bytes
   and zero-fills missing pages.
2. The WinFsp `Read` callback caps the requested length to
   `(size − offset)` and zero-fills any underdelivery.

If you still see it: rebuild from current `main`, or check whether
the file is in `/files/by-ino/` (uses a slightly different size policy
for inodes whose `i_size` is 0 — pseudo-fs files like
`/proc/meminfo`).

## "Cannot find 'Linux version' banner in dump"

```
Error: Cannot find 'Linux version' banner in dump — corrupt? Unsupported format?
```

The banner string couldn't be located in physical memory. Causes:

- **Truncated dump.** Verify the file size matches what you'd expect
  for the VM/host's RAM amount.
- **Wrong file format detected.** Run with `-v` and check the
  `Format:` line. If it says `raw` but the file is actually AVML, the
  reader won't decompress and you're reading Snappy frames as raw
  bytes. (Auto-detection looks at the first 64 bytes; some AVML files
  might have a header oddity.)
- **Not a Linux dump.** Windows or BSD memory dumps don't contain the
  `"Linux version "` string.

Diagnostic: `strings -n 20 <dump> | grep "Linux version"`. If
nothing matches, the dump genuinely doesn't have the banner.

If this command shows misleading strings like `Linux version %s (%s)` or
`Linux version of ...`, those are not enough to identify the kernel.
Current MemNixFS scores all banner candidates and only uses a
kernel-looking release string for automatic symbol selection.

## "LiME: truncated segment"

```
Error: LiME: truncated segment 3 at offset 0xbff66c60: PA range
0x100000000-0xdb6ffffff needs 0xcb7000000 bytes, but file has only ...
```

The LiME headers describe a physical memory range whose payload is not fully
present in the file. This is an incomplete acquisition, not a symbol problem.

Fix:

1. On the source Linux system, check `dmesg | tail -50` for LiME write errors.
2. Unload the current module with `sudo rmmod lime` before starting another
   capture.
3. Write the dump to storage with enough free space, preferably an attached
   disk rather than the live ISO overlay.
4. Recapture and copy the file only after the LiME command has completed.

## "ISF/dump MISMATCH"

```
[ERR] ===========================================================
[ERR]   ISF/dump MISMATCH! ISF is for kernel '6.17.0-3-generic' but the dump's
[ERR]   banner reports a different kernel. Struct field offsets
[ERR]   WILL be wrong (silently — many bugs look like this).
[ERR]   Pick the matching .json.xz from the symbols directory.
[ERR] ===========================================================
```

The ISF being used doesn't match the dump's kernel. This is a **loud
warning, not a hard error** — the engine will keep going, but every
field offset is potentially wrong, leading to nonsensical PIDs,
corrupted process names, etc.

The warning compares the ISF against the selected canonical banner, not
against arbitrary `Linux version` text recovered elsewhere in memory.

Fix:

1. **Check what release the dump is for:** `-v` shows
   `Detected kernel release: <release>`.
2. **Look in the cache:** `dir %LOCALAPPDATA%\MemNixFS\symbols\`.
3. **Pick the matching file** with `--symbols`, or delete the wrong
   one and re-run (the resolver will then try BTF+kallsyms or HTTP).

## "kallsyms extraction failed"

```
[WRN] kallsyms extraction failed: no token_index candidate produced a valid
       kallsyms layout — produced ISF will lack a symbols section
```

The dump doesn't contain a recognisable `kallsyms_token_index`. Causes:

- **Kernel built without `CONFIG_KALLSYMS=y`.** Very rare on distro
  kernels.
- **Kernel image was stripped after build.** Some embedded distros do
  this; standard distros don't.
- **Dump truncated before the .rodata section.**
- **Pre-CONFIG_KALLSYMS_BASE_RELATIVE layout** (kernel < 4.6) — not
  yet supported.

When this happens, the engine still works **if** the ISF has symbols
from elsewhere (`--symbols`, `--vmlinux`, HTTP cache, `--auto-fetch`).

## "No ISF found for kernel release X"

```
Error: No ISF found for kernel release '6.99.0-custom-build'.
Searched: (no --symbols path), ./symbols/linux/, $LMPFS_SYMBOL_CACHE,
%LOCALAPPDATA%/MemNixFS/symbols.

  # Refer to your distro's documentation for kernel-debug packages,
  # then run dwarf2json against the resulting vmlinux:
  dwarf2json linux --elf /path/to/vmlinux-6.99.0-custom-build | xz > out.json.xz
```

All 6 steps of the symbol resolver failed. Possibilities by step:

1. **BTF + kallsyms in dump:** kernel has no `.BTF` section AND
   kallsyms didn't decode. Pre-5.x kernel, custom build, or stripped
   image.
2. **Community HTTP mirror:** custom kernel build that nobody else
   built an ISF for. The mirror's keyed by SHA-256 of the banner.
3. **`--auto-fetch`:** distro repo doesn't have a `-dbgsym` package
   for that kernel.

Fix: feed `--vmlinux` if you have the vmlinux. Otherwise, see the
copy-pasteable command in the error message.

## "DTB resolution: no candidates"

```
Error: DTB resolution: no candidates (ISF missing init_top_pgt + no init_task + no banner)
```

The DTB scan couldn't even produce candidate values. Almost always
means the ISF is fundamentally wrong (missing critical symbols).

Fix: try a fresh ISF (`Remove-Item …\symbols`; rerun).

## "Brute-force scan completed: N pages, M plausible, NO match"

```
[WRN] Brute-force scan completed: 524288 pages, 233 plausible, NO match
```

The DTB resolver tried banner-anchored, init_task-anchored, AND
brute-force PGD scan; none of them produced a PGD that walks back to
`linux_banner`. The engine continues but `/sys/banner.txt` and any
kernel-VA reads will fail.

**Process listing still works** (it uses the direct map, not the DTB).
Most users won't notice unless they care about `/sys/banner.txt` or
future kernel-stack walking features.

Causes:

- `init_top_pgt` is the static (early-boot) PGD, abandoned after
  kernel init. Some kernels also lack `swapper_pg_dir`.
- The brute-force scan looks for a PGD whose 4-level walk yields the
  banner string at a known VA. If the dump has gaps near the running
  PGD, this fails.

## WinFsp mount not visible in Explorer

You ran `memnixfs ... mount M:` and Windows shows the drive in `wmic
logicaldisk`, but `M:\` doesn't appear in Explorer.

**Cause:** WinFsp mounts are scoped to the **logon session** that
creates them. If you launched MemNixFS from a different session (a
service, an SSH session, a different desktop), Explorer in your
interactive desktop can't see it.

Fix: launch from a console in the same desktop where you want to use
the mount. For globally-visible mounts, register with
`WinFsp.Launcher` (future work).

## WinFsp double-Close / crash

The WinFsp adapter is **stateless** — there's no per-Open allocation
and Close is a no-op, so double-Close IRPs are harmless. If you see a
crash on close anyway, it's a different bug — file an issue with the
WinFsp trace log.

## "Notepad++ keeps asking 'file modified, reload?'"

Old bug. Was caused by `fill_attr()` returning the current system time
for each query instead of the node's stable `ctime_`. **Fixed** —
update to the latest build.

## Slow startup

```
[INF] kallsyms: scanning 2048.0 MB for kallsyms_token_index...
[INF] kallsyms: 141 token_index candidate(s)
```

Scanning 2 GB takes a few seconds. This is fine. Most of it is AVML
decompression (Snappy is fast but not free).

On a 16 GB dump it'll be 20–30 seconds for the first run. Once an
ISF is cached, subsequent runs skip the scan.

To speed up dev iteration: pass `--symbols <path>` once you've got a
good ISF.

## "Empty process list"

```
[INF] Found 0 swapper candidates
…
Total: 0 processes
```

`scan_swapper()` failed to find the `swapper/0` comm signature. Causes:

- The dump genuinely has no kernel init thread (very rare; means kernel
  hasn't booted past very early init).
- The `comm` field offset in your ISF is wrong (mismatch warning
  should have fired).
- The dump is encrypted / scrambled (some VM hypervisors with full-VM
  encryption produce dumps you can't analyse without the key).

## "Listed N processes" but `tree` shows nothing

If process listing works but `tree` is empty, the VFS tree wasn't
built. Usually a missing field offset in the ISF for a downstream type
(e.g. `dentry`, `vm_area_struct`). Run with `-vv` for the trace.

## `proc.dmp` opens but reads return zeros

The process's `task->mm` is NULL (kernel thread — kernel threads
share the kernel address space, no user VMAs). MemNixFS still creates
`proc.dmp` for kernel threads but it's empty. Use `info.txt` to
distinguish:

```
$ cat M:\proc\2-kthreadd\info.txt
PID:        2
…
MM:         0x0       ← NULL → kernel thread
VMA_COUNT:  0
```

For user processes, `MM` will be a kernel VA.

## CMake build errors

See [Building from source](../building.md) for vcpkg / toolchain issues.

## Still stuck?

Open an issue with:

- The CLI invocation
- Full `-v` output (or `-vv` for tracing)
- Dump format, size, kernel version
- The exact error message

The first three are usually enough to diagnose.
