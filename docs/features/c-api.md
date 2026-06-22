# C API — `memnixfs.dll`

**One DLL, two audiences.** `memnixfs.dll` simultaneously exports:

| Surface | Header | Audience |
|---|---|---|
| Native `lmpfs_*` | `src/api/lmpfs.h` | native C/C++ + any C-FFI consumer |
| MemProcFS `VMMDLL_*` | `src/api/vmmdll_compat.h` | a MemProcFS-shaped `VMMDLL_*` C API |

Tested via two smoke programs — `c_api_smoke` and `vmmdll_smoke` — that
exercise every entry point against the same engine, including the
cross-translation invariant (`phys[PA] == kva[direct_map_base + PA]`) in both.

The DLL is built whenever the main project is built — it sits next to
`memnixfs.exe` in the same release directory.

## Surface

The complete public header is `src/api/lmpfs.h`. Fifteen entry points,
all `extern "C"`:

```c
/* library-wide */
const char* lmpfs_version(void);
const char* lmpfs_last_error(void);

/* lifecycle */
lmpfs_handle_t lmpfs_open(const char* dump_path, const char* symbols_path);
void           lmpfs_close(lmpfs_handle_t h);

/* processes */
int lmpfs_process_count(lmpfs_handle_t h);
int lmpfs_process_get(lmpfs_handle_t h, int index, lmpfs_process_t* out);
int lmpfs_process_find_by_name(lmpfs_handle_t h, const char* name, lmpfs_process_t* out);
int lmpfs_process_find_by_pid (lmpfs_handle_t h, uint32_t pid,    lmpfs_process_t* out);

/* virtual filesystem */
int     lmpfs_vfs_list     (lmpfs_handle_t h, const char* path,
                            lmpfs_dir_entry_t** entries, int* count);
void    lmpfs_vfs_list_free(lmpfs_dir_entry_t* entries);
int64_t lmpfs_vfs_size     (lmpfs_handle_t h, const char* path);
int64_t lmpfs_vfs_read     (lmpfs_handle_t h, const char* path,
                            uint64_t offset, void* buf, size_t len);

/* raw memory */
int64_t lmpfs_mem_read_phys(lmpfs_handle_t h, uint64_t pa, void* buf, size_t len);
int64_t lmpfs_mem_read_kva (lmpfs_handle_t h, uint64_t va, void* buf, size_t len);

/* kernel context */
int      lmpfs_kernel_banner          (lmpfs_handle_t h, char* out, size_t out_size);
uint64_t lmpfs_kernel_direct_map_base (lmpfs_handle_t h);
int64_t  lmpfs_kernel_kaslr_phys_shift(lmpfs_handle_t h);
```

## Error model

| Return shape | Failure value |
|---|---|
| Pointer | `NULL` |
| bool-int (success = 1) | `0` |
| byte-count `int64_t` (read, size) | `-1` |
| Count `int` (process_count) | `-1` |

After **any** failure, `lmpfs_last_error()` returns a thread-local
human-readable message. Each thread sees its own message — safe to use
from a thread pool without locks. Cleared at the start of every
successful operation.

## Threading

* The engine itself is thread-safe (WinFsp dispatches concurrent reads
  through it).
* All `lmpfs_*` handle operations are thread-safe.
* `lmpfs_last_error` is **thread-local**: call it from the thread that
  just got the failure return value.

## Minimal C consumer

```c
#include "api/lmpfs.h"
#include <stdio.h>

int main(int argc, char** argv) {
    if (argc < 2) return 2;
    lmpfs_handle_t h = lmpfs_open(argv[1], argc > 2 ? argv[2] : NULL);
    if (!h) {
        fprintf(stderr, "open failed: %s\n", lmpfs_last_error());
        return 1;
    }
    char banner[256];
    lmpfs_kernel_banner(h, banner, sizeof(banner));
    printf("kernel: %s\n", banner);
    printf("processes: %d\n", lmpfs_process_count(h));
    lmpfs_close(h);
}
```

Link against `memnixfs.lib` (import library) or load `memnixfs.dll`
dynamically with `LoadLibrary` + `GetProcAddress`. The smoke driver
at `tests/c_api/c_api_smoke.cpp` exercises every entry point.

## MemProcFS `VMMDLL_*` surface (v0.24)

The same DLL also exports a MemProcFS-shaped `VMMDLL_*` C API
(`src/api/vmmdll_compat.h`), mirroring the `vmm.dll` entry points:

```c
#include "vmmdll_compat.h"
const char* argv[] = { "", "-device", "dump.raw", "-symbol", "isf.json" };
VMM_HANDLE h = VMMDLL_Initialize(5, argv);

DWORD pid = 0;
VMMDLL_PidGetFromName(h, "systemd", &pid);
printf("systemd pid=%u\n", pid);

VMMDLL_Close(h);
```

Functions shipped: `Initialize` / `Close` / `CloseAll` /
`VfsListU` (callback dispatch) / `VfsReadU` (NTSTATUS) /
`MemRead` / `MemReadEx` / `PidList` (two-call NULL-then-fill) /
`PidGetFromName` / `ConfigGet` / `ConfigSet`.

Argv parsing is **lenient by design** — unrecognised flags like
`-waitinitialize` / `-symbolserverdisable` are silently dropped so
MemProcFS-targeted scripts don't fail on flags that don't apply to us.

## What's NOT in the C API

* No `lmpfs_mount()` — that's a WinFsp specific surface. The DLL is for
  programmatic access; the CLI's `mount` subcommand is the right path
  if you want a filesystem.
* No callback-style `VfsList` (MemProcFS does this). We return a
  caller-owned array instead — simpler for FFI consumers, easier to
  free correctly.
* No write APIs. The engine is read-only by design — dumps are
  snapshots.
