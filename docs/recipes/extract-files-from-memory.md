# Recipe — Extract files from a Linux memory dump

> Goal: pull a file out of the dump even when no process currently has it
> open. Same workflow as Volatility 3's `linux.pagecache.RecoverFs`, but
> as a folder you can browse.

---

## TL;DR

```powershell
# 1. Mount
memnixfs.exe --dump suspicious.lime mount M:

# 2. Browse the reconstructed root filesystem at its REAL global paths
explorer M:\fs

# 3. Or grep / copy directly
copy "M:\fs\usr\lib\os-release" .\
findstr /S "PRETTY_NAME" "M:\fs\etc\*"
type "M:\fs\run\systemd\resolve\stub-resolv.conf"
```

## What's available

| Path                                        | What it gives you                                                       |
|---------------------------------------------|-------------------------------------------------------------------------|
| `M:\fs\…`                                   | **Reconstructed root filesystem at real global paths.** Browse like the running machine's `/`. |
| `M:\sys\mountinfo`                     | Every mount in the init namespace (`/proc/mountinfo` format)            |
| `M:\sys\pagecache\index.txt`           | Catalog: every cached inode + size + path                               |
| `M:\files\by-ino\<fs>-<ino>.bin`            | Flat per-inode view (forensic fallback for deleted-but-cached files)    |

## Step-by-step

### 1. See what's cached

```powershell
PS> memnixfs --dump dump.lime cat /sys/pagecache/index.txt | findstr ".conf"
ext4         REG   rw-------       7351   2          6531  /etc/security/limits.conf
squashfs     REG   rw-r--r--       3941   1          1234  /etc/fonts/conf.d/...
...
```

Field order: `fs  type  perms  ino  cached  size  path`.

* `cached` is the number of 4 KiB pages currently in the page cache.
* `size` is the inode's logical size (bytes).
* `path` is the **fs-local** path (mount-prefix not composed; see caveats).

### 2. Recover a specific file

**Preferred — at its real global path (after mount, just open in Explorer)**:
```powershell
type "M:\fs\usr\lib\os-release"
type "M:\fs\run\systemd\resolve\stub-resolv.conf"
type "M:\fs\snap\core22\2045\usr\lib\os-release"
```

**Or via `cat` from the CLI:**
```powershell
memnixfs --dump dump.lime cat /fs/etc/security/limits.conf > limits.conf
```

**Or by inode number (for deleted-but-cached files that lost their path):**
```powershell
memnixfs --dump dump.lime cat /files/by-ino/ext4-7351.bin > limits.conf
```

### 3. Hunt for evidence

```powershell
# Find all shell scripts cached in memory
PS> memnixfs --dump dump.lime cat /sys/pagecache/index.txt | findstr "\.sh"

# Pull just the shell scripts under /tmp (often where attackers stage things)
PS> Get-ChildItem M:\fs\tmp -Recurse -Filter *.sh

# Look for crontab residue
PS> Get-ChildItem M:\fs\etc\cron.* -Recurse 2>$null
PS> Get-ChildItem M:\fs\var\spool\cron 2>$null

# Bash histories of every user
PS> Get-ChildItem M:\fs\home\*\.bash_history,M:\fs\root\.bash_history
```

## Caveats (read these)

1. **Resident pages only.** If no content pages were cached, opening the file
   under `/fs` returns an `unavailable` explanation rather than fake bytes. If
   some pages were cached, missing ranges inside the file may still read as
   synthetic zeros; a 500 MB log file with only the last 1 MB cached can read as
   499 MB of zeros followed by the actual tail. `strings` is your friend, but
   check `/sys/pagecache/recovery.txt` before treating zero ranges as evidence.

2. **Compressed filesystems.** squashfs / btrfs / zstd pages: what's
   in the page cache is the **decompressed** content (that's the form
   the kernel hands to user space). So binaries from snap mounts come
   out as ordinary ELFs, not compressed blobs.

3. **Deleted but cached.** If `unlink()`'d while still open, the inode
   stays in memory but the dentry goes away — the file is hidden from
   `/fs/` but still reachable through `/files/by-ino/`. Look for
   `nr_cached > 0 && i_size > 0` with `(anon)` path in the catalog.

4. **Symlinks are text files for now.** MemNixFS tries to recover the
   target from `inode.i_link` and then from cached symlink content. If the
   target is unavailable, the file contains the recovery reason instead of
   pretending the target was known.

## What the underlying machinery does

For each inode, MemNixFS:

1. Reads `inode.i_data.i_pages` — an xarray (radix tree of cached folios).
2. For each cached folio pointer found in the tree:
   * Computes `PFN = (folio_va - vmemmap_base) / 64`.
   * Reads `PFN << 12` from physical memory (4 KiB).
   * Writes that page at offset `folio.index * 4096` in the reassembled
     file.
3. Truncates to `min(inode.i_size, max_index*4096)`.

See [features/pagecache.md](../features/pagecache.md) for the design notes.

## Cross-references

| You want…                                | …go look at                                |
|------------------------------------------|--------------------------------------------|
| What's the design?                       | [features/pagecache.md](../features/pagecache.md) |
| The equivalent vol3 plugin               | `linux.pagecache.RecoverFs`                |
| Source code                              | `src/os/linux/pagecache.{h,cpp}`           |
| How paths get resolved                   | `src/os/linux/dentry_path.{h,cpp}`         |
| Multi-strategy kernel-VA reads           | `src/os/linux/kva_reader.{h,cpp}`          |
