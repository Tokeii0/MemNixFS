# Live mount

The `mount` command exposes the dump as a live read-only filesystem on
the host OS. Windows builds use [WinFsp](https://winfsp.dev/). Linux builds
use libfuse3.

## Setup

### Windows

Install WinFsp from https://winfsp.dev/rel/ (default location:
`C:\Program Files (x86)\WinFsp`). Then build MemNixFS with
`-DLMPFS_BUILD_MOUNT_WINFSP=ON`:

For building, the WinFsp SDK must be installed, not just the runtime.
Check for both files before configuring:

```powershell
Test-Path "C:\Program Files (x86)\WinFsp\inc\winfsp\winfsp.h"
Test-Path "C:\Program Files (x86)\WinFsp\lib\winfsp-x64.lib"
```

If either prints `False`, the installed WinFsp package can run existing
WinFsp filesystems but cannot compile MemNixFS's mount backend.

```powershell
cmake --preset msvc-x64 -DLMPFS_BUILD_MOUNT_WINFSP=ON
cmake --build build/msvc-x64 --config Release
```

### Linux

Install the development dependencies, including libfuse3:

```bash
sudo apt install build-essential cmake ninja-build pkg-config \
  fuse3 libfuse3-dev libsnappy-dev liblzma-dev nlohmann-json3-dev \
  libfmt-dev libyara-dev

cmake -S . -B build/linux-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLMPFS_BUILD_MOUNT_FUSE=ON \
  -DLMPFS_BUILD_MOUNT_WINFSP=OFF
cmake --build build/linux-release --target memnixfs
```

## Mounting

```powershell
# Mount to drive letter M:
.\build\msvc-x64\Release\memnixfs.exe --dump output.lime.compressed mount M:

# Or mount to an empty directory
.\build\msvc-x64\Release\memnixfs.exe --dump output.lime.compressed mount C:\mnt\dump
```

```bash
mkdir -p /tmp/memnixfs
./build/linux-release/memnixfs --dump output.lime.compressed --forensic mount /tmp/memnixfs
ls /tmp/memnixfs
fusermount3 -u /tmp/memnixfs   # Linux
```

The mount stays alive until you Ctrl-C the process. The filesystem is
**read-only**. On Linux, unmount from another shell with the platform
command shown above.

## Visibility caveat

WinFsp mounts are visible to the **logon session** that creates them.
If you mount from cmd / PowerShell, Explorer in that desktop sees the
drive normally. If you spawn `memnixfs.exe` from a different
sandbox/service, the mount won't be reachable from your desktop.

This is a Windows / WinFsp behavior, not a MemNixFS bug. For
globally-visible mounts, register the EXE with `WinFsp.Launcher` (future
work — `LauncherSDK`).

## What you can do once mounted

Anything Windows can do to a regular drive:

```powershell
# Explorer: just browse M:\
explorer M:\

# Strings on a process's memory
type M:\proc\3096-firefox\proc.dmp | findstr "password"

# Open a hex view of all physical memory
HxD.exe M:\mem\phys.raw

# Open a hex view of the kernel virtual-address space (128 TiB sparse;
# only mapped pages return non-zero bytes, the rest is zero-fill).
# Jump to any kernel symbol's VA - 0xffff800000000000 to inspect it.
HxD.exe M:\mem\kern_va.raw

# Ad-hoc VA→PA / PA→VA translation (path-encoded query):
type M:\misc\virt2phys\0xffffffffa7fb3580
type M:\misc\phys2virt\0x48bb3580

# Triage report — what's running, what's hooked, what's monitoring this box.
# Start here when opening a new dump.
type M:\forensic\snapshot.txt

# AV/EDR detection (signature-match against ~30 endpoint products):
type M:\sys\findevil\av_edr.txt

# SIEM-friendly JSON exports (jq / pandas / pipe-into-Splunk):
type M:\sys\processes\pslist.json | jq '.[] | select(.uid == 0)'
type M:\sys\findevil\malfind.json
type M:\forensic\snapshot.json

# Per-process supplementary info:
type M:\proc\4849-bash\libs.txt          # shared libs grouped by path
type M:\proc\4849-bash\ptrace.txt        # ptrace relationships
type M:\proc\4849-bash\strings.txt       # printable ASCII strings

# Global IOC sweep across every user process (URLs, IPv4, emails, ...)
type M:\search\iocs.txt

# YARA scan across every user task's readable VMAs (~40s on a desktop dump).
# Drop your own .yar files into %LOCALAPPDATA%\MemNixFS\yara\ or set
# $LMPFS_YARA_RULES to override.
type M:\search\yara.txt

# Per-process YARA scope (much faster — single task's VMAs only):
type M:\proc\4849-bash\yara.txt

# Diff two VMAs
fc /b M:\proc\1234-binary\proc.dmp M:\proc\5678-binary\proc.dmp

# Read kallsyms with awk-style tools (need a POSIX shell)
type M:\sys\kallsyms | findstr /R " T do_init_module"

# Search a process's memory for a string pattern
findstr /M /R "[a-z]*@[a-z.]*" M:\proc\3096-firefox\proc.dmp
```

## Implementation notes

### Stateless callbacks
`src/mount/winfsp_mount.cpp` registers WinFsp callbacks that operate
**without any per-Open allocation**. The trick:

- Every VFS node lives forever in the engine's tree (no eviction).
- WinFsp's `fctx` opaque pointer carries a raw `Node*`.
- `Open` just dereferences the path, stores the `Node*` in `fctx`,
  returns `STATUS_SUCCESS`.
- `Close` is a no-op.

This pattern (lifted from MemProcFS) sidesteps WinFsp's known
duplicate-Close-IRP behaviour. Per-Open `new`/`delete` is a classic
double-free trap.

### Stable timestamps
`fill_attr()` reports each node's `ctime_` (set when the engine builds
the tree) for *all* of `CreationTime`, `LastWriteTime`,
`LastAccessTime`, `ChangeTime`. Windows applications that compare
timestamps across queries (Notepad++, VS Code) see stable values and
don't issue "file modified, reload?" prompts.

### Volume label
Currently hardcoded to `MemNixFS`. Shows up in Explorer's "This PC"
view as the drive's label.

### Streaming reads
`Read` callbacks call `Node::read(offset, len)` which for
`StreamFileNode` (proc.dmp, phys.raw) reads only the requested range
on demand. Multi-GB `proc.dmp` files don't materialise in RAM.

### Delay-loaded DLL
WinFsp's `winfsp-x64.dll` is linked with `/DELAYLOAD`. The EXE can
launch on machines without WinFsp; only `mount` triggers loading. If
the DLL is missing, the user gets a clear error rather than a load-time
crash.

We also `LoadLibrary("winfsp-x64.dll")` from the canonical install
path (`C:\Program Files (x86)\WinFsp\bin\`) before the first WinFsp
call, so the user doesn't need to add it to PATH.

## Unmounting

Send `Ctrl-C` to the `memnixfs.exe` process running the mount. Windows
will release the drive letter / directory.

If `memnixfs.exe` crashed and left a stale mount, use:

```powershell
& "C:\Program Files (x86)\WinFsp\bin\fsptool-x64.exe" unmount M:
```

## What if WinFsp isn't installed?

Three options:

1. **Install WinFsp**. It's small (~2 MB) and stable.
2. **Use `export` instead** of `mount`:
   ```powershell
   memnixfs --dump <file> export C:\mnt\dump_static
   ```
   Materialises the tree to a real folder. No mount needed. Slower
   start (large files written to disk) but no runtime dependency.
3. **Build without WinFsp** — the default. `mount` will simply be
   unavailable; other commands work fine.

## Performance

| Operation | Speed |
|---|---|
| Directory listing | < 1 ms (in-memory) |
| Small file read (`info.txt`, `cmdline`, …) | < 1 ms (regenerated on each open; results are small) |
| Random read on `proc.dmp` | ~100 µs per 4 KiB (cache hit), ~5 ms (miss, AVML decompress) |
| Sequential read on `proc.dmp` | ~50 MB/s steady-state |
| Random read on `phys.raw` | Same as `proc.dmp` (via PhysicalLayer) |
| Mmap'd raw dump random read | 833 MB/s (measured, OS page cache) |

## Reference

- WinFsp docs: https://winfsp.dev/doc/
- MemProcFS WinFsp adapter: `vmm/oscompatibility.c`, `vmm/m_winfsp.c`
- The "stateless callbacks" pattern: same source files in MemProcFS
