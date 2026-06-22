# Offline workflows

How to run MemNixFS in air-gapped environments — no internet, no
external files, no toolchain — and still get a fully functional VFS.

## TL;DR

For any modern distro kernel (Ubuntu ≥ 20.04, Fedora ≥ 32, RHEL ≥ 8.2,
Alpine ≥ 3.16, recent Debian/Arch/openSUSE — i.e. just about anything
made in the last 5 years):

```powershell
memnixfs --dump <file> --no-http-cache list
```

That's it. No `--symbols`, no `--vmlinux`, no `--auto-fetch`. The
BTF + kallsyms parser synthesises an ISF from the dump's own bytes
and runs against it. ~3 seconds to first process listing.

## Why does this work?

Modern Linux kernels carry **two** things inside their image that we
need:

1. **`.BTF` section** (~3–7 MB) — every kernel type definition
   (`task_struct`, `mm_struct`, `vm_area_struct`, etc.) with byte-exact
   field offsets.
2. **`kallsyms`** (~100k–250k entries) — every kernel symbol's name +
   virtual address.

Both go into the dump verbatim. MemNixFS extracts both and merges them
into a Volatility-3 ISF. See [BTF→ISF](../features/btf-to-isf.md) and
[kallsyms](../features/kallsyms.md) for the technical details.

## Verifying the offline path is in use

Run with `-v` to see which resolver step won:

```
[INF] Auto-picked ISF from cache C:\…\6.14.0-36-generic.json.xz
[INF] Loading symbols: …\6.14.0-36-generic.json.xz (auto-discover-cache)
```

If you see `(auto-discover-cache)`, you're hitting a previously-cached
ISF. To force fresh extraction:

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\MemNixFS\symbols"
memnixfs --dump <file> --no-http-cache -v list
```

You'll then see:

```
[INF] Extracting kallsyms from the dump...
[INF] kallsyms: 135809 symbols (relative_base = 0xffffffff9b000000)
[INF] BTF scan: 91 blob(s) found; largest = 4244721 bytes @ PA 0x19b9530
[INF] Trying BTF→ISF from blob #2 (4244721 bytes @ PA 0x1e2def98)
[INF] BTF→ISF: wrote …\6.12.1-3-virt.json.xz (82608 types, 122487 symbols, …)
[INF] BTF→ISF: generated … (82608 types, 122487 symbols) — using as our ISF
[INF] Loading symbols: …\6.12.1-3-virt.json.xz (btf+kallsyms-from-dump)
```

The trailing `(btf+kallsyms-from-dump)` tag confirms the offline path
won.

## When BTF + kallsyms isn't enough

### Pre-CONFIG_DEBUG_INFO_BTF kernels

Linux < 5.x typically lacks `CONFIG_DEBUG_INFO_BTF=y`. Affected
distros (heuristic — check your specific kernel):

- Ubuntu 18.04 LTS (Bionic)
- RHEL 7, CentOS 7
- Debian 9 (Stretch) and earlier
- Anything sufficiently old

For these dumps, BTF is absent → only kallsyms resolves (we'd have
symbols but no types). MemNixFS currently treats this as a hard
failure and tells you to use `--symbols` or `--vmlinux`.

### Custom or stripped kernels

If someone explicitly built a kernel with `CONFIG_DEBUG_INFO_BTF=n` or
disabled kallsyms, the offline path can't synthesise an ISF.

## Alternative offline paths

### `--vmlinux` (offline with a local vmlinux)

If you have the vmlinux file (e.g. from a build artifact, an extracted
`.ddeb`, or a `vmlinuz` you ran `extract-vmlinux` on):

```powershell
memnixfs --dump <file> --vmlinux ./vmlinux-6.14 <command>
```

This invokes `dwarf2json` via WSL on Windows to produce a full
DWARF-based ISF. Higher fidelity than BTF (carries debug info BTF
omits — source locations, inline function ranges, complete enum value
names, …) but rarely needed in practice.

### `--symbols PATH` (offline with a pre-built ISF)

If you've been given (or pre-fetched) an ISF for this kernel:

```powershell
# Exact file:
memnixfs --dump <file> --symbols ./isf-archive/6.14.0-36-generic.json.xz <command>

# A directory of ISFs:
memnixfs --dump <file> --symbols ./isf-archive/ <command>
```

The directory mode walks looking for any `.json[.xz]` whose
`metadata.linux.symbols[0].name` matches the dump's release.

## Air-gap workflow

For environments where the analyst's workstation has no internet:

1. **On a connected machine**, build the ISF archive once:

   ```bash
   for release in 6.14.0-36-generic 6.12.1-3-virt 6.8.0-50-generic …; do
     wsl bash -lc "tools/fetch_symbols.sh '$release' '/tmp/$release.json.xz'"
   done
   ```

2. **Copy the resulting `.json.xz` files** to the air-gapped machine
   into `%LOCALAPPDATA%\MemNixFS\symbols\` (Windows) or
   `~/.cache/lmpfs/symbols/` (Unix).

3. **On the air-gapped machine**, run normally:

   ```powershell
   memnixfs --dump <file> <command>
   ```

   The local-cache step finds the right ISF and uses it.

## Performance

| Path | Time to first process listing | Notes |
|---|---|---|
| Cache hit | ~0.5 s | JSON parsing dominates |
| BTF + kallsyms (cold) | ~3 s | kallsyms scan + BTF parse + serialize |
| `--vmlinux` (via WSL) | ~30 s | `dwarf2json` is the bottleneck |
| `--auto-fetch` (network) | ~60–180 s | Distro repo + package extraction |

## Disabling network entirely

```powershell
memnixfs --dump <file> --no-http-cache <command>
```

`--no-http-cache` disables the community-mirror lookup (step 5 of the
resolution chain). Without it, with `--auto-fetch` off (the default),
MemNixFS makes zero network calls. Combined with BTF + kallsyms in
the dump, you have a 100% offline tool.

To prove this, you can run with the Windows firewall blocking
`memnixfs.exe` outbound — works fine.
