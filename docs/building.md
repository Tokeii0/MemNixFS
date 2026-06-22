# Building from source

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Windows | 10 or 11 | x64 |
| MSVC | 2022 (17.x) | Comes with Visual Studio 2022 Community/Pro |
| CMake | ≥ 3.20 | https://cmake.org/download/ |
| vcpkg | latest | https://github.com/microsoft/vcpkg |
| WinFsp | 2.0+ | Windows live mount backend |
| FUSE | libfuse3 | Linux live mount backend |

WSL is not required for Windows builds. It is useful for verifying the Linux
host build from a Windows workstation, and `--auto-fetch` on Windows still
uses WSL to run the symbol-fetch helper.

Linux host builds require a C++17 compiler, CMake, pkg-config, Snappy,
liblzma, nlohmann-json, fmt, optional libyara, and libfuse3 for live mounts.

## Step 1 — Clone

```powershell
git clone https://github.com/MemNixFS/MemNixFS-dev.git
cd MemNixFS-dev
```

## Step 2 — Install vcpkg dependencies

`vcpkg.json` in the repo root declares everything we need:

```json
{
  "dependencies": [ "snappy", "liblzma", "nlohmann-json", "fmt", "yara" ]
}
```

The `msvc-x64` preset locates vcpkg through the **`VCPKG_ROOT`** environment
variable, so set it to your vcpkg checkout (persist it for new shells):

```powershell
[Environment]::SetEnvironmentVariable('VCPKG_ROOT', 'C:\path\to\vcpkg', 'User')
$env:VCPKG_ROOT = 'C:\path\to\vcpkg'   # also set it for the current shell
```

With `VCPKG_ROOT` set (and `vcpkg` on your `PATH`), the build auto-resolves
everything via manifest mode. Otherwise:

```powershell
# Manual install (if not using manifest mode)
vcpkg install snappy:x64-windows liblzma:x64-windows `
              nlohmann-json:x64-windows fmt:x64-windows yara:x64-windows
```

Newer vcpkg releases require a manifest `builtin-baseline`. The repo's
`vcpkg.json` includes one; if you replace the manifest or use a different
registry, keep the baseline pinned or CMake configure can fail before
dependency restore starts.

## Step 3 — Configure

The repo ships a CMake preset (`CMakePresets.json`) named `msvc-x64`:

```powershell
cmake --preset msvc-x64
```

This sets:

- `CMAKE_TOOLCHAIN_FILE` → `$env{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake`
  (so **`VCPKG_ROOT` must be set** — see Step 2)
- `VCPKG_TARGET_TRIPLET` → `x64-windows`
- `LMPFS_BUILD_MOUNT_WINFSP=ON` (mount is the primary UX; ON by default)

If WinFsp isn't installed the configure will hard-fail with a pointer to
[https://winfsp.dev/](https://winfsp.dev/). To intentionally build a
CLI-only test binary (no `mount` subcommand), pass
`-DLMPFS_BUILD_MOUNT_WINFSP=OFF`.

If your vcpkg lives somewhere else, just point `VCPKG_ROOT` at it
(`$env:VCPKG_ROOT = 'D:\path\to\vcpkg'`) — no need to edit the preset. You can
also pass `-DCMAKE_TOOLCHAIN_FILE=...` directly to override it.

For a CLI-only developer build without the WinFsp SDK, use a separate build
directory so the normal mount-enabled preset stays clean:

```powershell
cmake -S . -B build/msvc-x64-cli -G "Visual Studio 18 2026" -A x64 `
  -DCMAKE_TOOLCHAIN_FILE="$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows `
  -DVCPKG_INSTALLED_DIR="$PWD/vcpkg_installed" `
  -DLMPFS_BUILD_MOUNT_WINFSP=OFF
```

For a Linux build with the FUSE mount backend:

```bash
sudo apt install build-essential cmake ninja-build pkg-config \
  fuse3 libfuse3-dev libsnappy-dev liblzma-dev nlohmann-json3-dev \
  libfmt-dev libyara-dev

cmake -S . -B build/linux-release -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLMPFS_BUILD_MOUNT_FUSE=ON \
  -DLMPFS_BUILD_MOUNT_WINFSP=OFF
```

If you are verifying through WSL and package installation fails with
`Temporary failure resolving`, fix WSL networking/DNS first; the build cannot
find the Linux development headers until `apt` can reach the distro mirrors.

## Step 4 — Build

```powershell
cmake --build build/msvc-x64 --config Release
```

Output binary: `build/msvc-x64/Release/memnixfs.exe` (~2 MB).

For the CLI-only build directory above:

```powershell
cmake --build build/msvc-x64-cli --config Release --parallel 8
Copy-Item .\vcpkg_installed\x64-windows\bin\*.dll .\build\msvc-x64-cli\Release\ -Force
```

For the Linux build directory above:

```bash
cmake --build build/linux-release --target memnixfs
```

## Step 5 — (Optional) WinFsp mount

To enable the `mount` command:

1. Install WinFsp from https://winfsp.dev/rel/ (default location:
   `C:\Program Files (x86)\WinFsp`).
2. Confirm the SDK files exist:

```powershell
Test-Path "C:\Program Files (x86)\WinFsp\inc\winfsp\winfsp.h"
Test-Path "C:\Program Files (x86)\WinFsp\lib\winfsp-x64.lib"
```

Both commands must print `True`. If only `bin\winfsp-x64.dll` exists,
the WinFsp runtime is installed but the SDK is not; CMake cannot build
the `mount` command until the SDK headers and import library are present.

3. Reconfigure with the option enabled:

```powershell
cmake --preset msvc-x64 -DLMPFS_BUILD_MOUNT_WINFSP=ON
cmake --build build/msvc-x64 --config Release
```

The build links against `winfsp-x64.lib` with `/DELAYLOAD:winfsp-x64.dll`,
so the executable can launch without WinFsp installed — only `mount`
will fail (with a clear error) on machines where the DLL isn't present.

## Quick sanity check

```powershell
# Should print usage:
.\build\msvc-x64\Release\memnixfs.exe -h

# Test against the bundled dump (if available):
.\build\msvc-x64\Release\memnixfs.exe `
   --dump "..\Test Image\output.lime.compressed" `
   --no-http-cache `
   list
```

Expected: a few seconds, then a process table. The count depends on the
dump;

## Build options

| CMake option | Default | What it does |
|---|---|---|
| `LMPFS_BUILD_MOUNT_WINFSP` | ON on Windows, OFF elsewhere | Build the WinFsp adapter (`mount` command). Hard-errors if the WinFsp SDK isn't installed at `C:\Program Files (x86)\WinFsp`. |
| `LMPFS_BUILD_MOUNT_FUSE` | ON on Linux, OFF on Windows | Build the FUSE adapter (`mount` command). Requires pkg-config and libfuse3 headers. |
| `LMPFS_BUILD_TESTS` | OFF | Build unit tests (`tests/` directory) |

Reconfigure with `-DLMPFS_BUILD_MOUNT_WINFSP=OFF` if you need a
CLI-only build for testing on a machine without WinFsp; the `mount`
subcommand will be missing, but `list`, `tree`, `cat`, `dmesg`, etc.
all still work.

## Packaging

CPack is enabled for installable artifacts. On every platform it can produce
portable `.zip` and `.tar.gz` archives. On Linux it also enables DEB/RPM
generators when the corresponding packaging tools are available:

```bash
cmake --build build/linux-release --target package
```

## Troubleshooting

### "Could NOT find Snappy" (or similar)
Your vcpkg isn't being found. Either:
- Set `VCPKG_ROOT` and let CMake pick it up via the preset's
  `CMAKE_TOOLCHAIN_FILE`.
- Or pass `-DCMAKE_TOOLCHAIN_FILE=<path>/scripts/buildsystems/vcpkg.cmake`
  directly.

### "winfsp.h: No such file or directory"
WinFsp isn't installed at the default location. Either install it from
https://winfsp.dev/rel/ or edit `CMakeLists.txt`'s `WINFSP_INC` /
`WINFSP_LIB` paths.

### "fatal error C1083: Cannot open include file 'fmt/format.h'"
vcpkg integration broke. Re-run `vcpkg install` and reconfigure. Make
sure `CMAKE_TOOLCHAIN_FILE` points to vcpkg's `vcpkg.cmake`.

### Build is slow
Use a multi-core build:

```powershell
cmake --build build/msvc-x64 --config Release --parallel 8
```

## Output layout

After a Release build:

```
build/msvc-x64/Release/
├── memnixfs.exe         ← the CLI binary
├── memnixfs_core.lib    ← static engine library (linkable for tests)
└── …
```

Distribute just `memnixfs.exe` plus, if you want the mount command,
ask the user to install WinFsp.
