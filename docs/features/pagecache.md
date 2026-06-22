# Page-cache enumeration & file-content recovery

**Status:** v0.37 — enumeration + content recovery + full `/fs/` reconstruction with global paths, including **symbol-free (BTF-only) dumps** via a derived `vmemmap_base` (added in v0.31).
**Source:** `src/os/linux/pagecache.{h,cpp}`, `src/os/linux/dentry_path.{h,cpp}`, `src/os/linux/mountinfo.{h,cpp}`
**Engine wiring:** `src/app/engine.cpp` (`/fs/` + `/files/` trees), `src/vfs/sys_module.cpp` (`/sys/pagecache/`, `/sys/mountinfo`)
**Cross-ref:** vol3 `linux.pagecache.{Files, RecoverFs, InodePages}`, MemProcFS `m_proc_file_handles.c`

---

## The forensic motivation

`task->files->fdt->fd[]` only shows files that some live process holds open
right now. Everything else — scripts a defunct cron job ran an hour ago, the
bash history of a user who SSH'd out, dropped malware, config snapshots, log
lines that were paged in but the writer has long since exited — lives only in
the **page cache**, behind no fd.

The kernel's page cache is keyed by `(inode, file_offset)` and persists for as
long as the kernel wants to keep the inode around (often well after the last
fd that referenced it is closed). If we can enumerate every in-memory inode
and walk its cached pages, we can recover any file that's been touched
recently — even if no process currently has it open.

## What we expose

```
/fs/                           ← reconstructed root filesystem. The
    bin -> usr/bin               primary "browse the system" UX. Every
    etc/                         inode with a resolvable global path
        os-release               lives here, mount-composed.
    home/ubuntu/.bash_history    (8 k+ dirs, 17 k+ files, 3 k+ symlinks
    run/systemd/resolve/...       on the Ubuntu test dump)
    snap/core22/2045/usr/bin/bash
    snap/firefox/7423/usr/lib/firefox/firefox
    usr/lib/os-release
    var/...

/sys/pagecache/index.txt  ← FULL catalog of every cached inode
/sys/mountinfo            ← /proc/mountinfo equivalent, 41 mounts

/files/                        ← ORPHAN-only view (v0.7 refocus):
    README.txt                   inodes WITHOUT a global path. The
    index.txt                    forensically-interesting cases:
    by-ino/                       * deleted-<fs>-<ino>.bin   (i_state has
        deleted-<fs>-<ino>.bin       I_FREEING / I_WILL_FREE: unlink()'d
        orphan-<fs>-<ino>.bin        while still open; content recoverable)
                                  * orphan-<fs>-<ino>.bin    (no dentry chain
                                     or no mount context — path unresolvable)
                               Files with valid paths live in /fs/, not here.
```

A real run on a 2 GB Ubuntu desktop dump catalogues ~30 000 inodes across
~95 superblocks. The `/fs/` tree contains every inode with a resolvable
path (~30 000 — directories, regular files, symlinks). The
`/files/by-ino/` tree contains ~360 regular files with at least one page
cached (deduplicated by inode).

`/fs/` is meant to be the recovered global Linux filesystem tree. Pseudo
filesystems such as `sysfs`, `proc`, `cgroup`, `cgroup2`, `debugfs`,
`tracefs`, `securityfs`, `configfs`, `bpf`, `pstore`, and `efivarfs` remain
visible in `/sys/pagecache/index.txt`, but they are filtered from `/fs/`
so synthetic sysfs/cgroup paths do not appear as confusing top-level
filesystem content. Real disk-backed paths named `/fs` are not hidden by this
filter.

`/fs/` also applies a conservative path trust gate. A recovered dentry path is
exposed only when the dentry still points back to the same inode and every path
component is display-safe: printable, free of control bytes and host-forbidden
characters, and — for non-ASCII names — **well-formed UTF-8** (so legitimate
international filenames are kept, while corrupt or overlong/surrogate byte
sequences are not). Names that fail are not rewritten into plausible-looking
underscores; they are skipped from `/fs` and listed with reasons in
`/sys/pagecache/path_quality.txt`.

## Algorithm (one screen)

```
A) Mount enumeration (mountinfo.cpp)
   1. init_task → nsproxy → mnt_ns → root (struct mount *)
   2. DFS via mount.mnt_mounts (children list) / mount.mnt_child (linkage)
   3. For each mount, compose global path:
        if mount.mnt_parent == self → "/"
        else → dentry_to_path(mount.mnt_mountpoint, parent.vfsmount)
              (dentry_to_path itself crosses further mounts upward)
   4. Build map: sb_va → primary vfsmount_va

B) Inode enumeration (pagecache.cpp) — THREE TIERS, tried in order
   Each tier produces an inode list; the first that works on a given dump
   wins. (a) is the definitive view on symbol-rich dumps; (c) is what keeps
   /fs and /files populated on BTF-only ISFs with no kernel symbols at all.

   (a) Global `inode_hashtable` walk  ← definitive, symbol-rich dumps
       Needs the `inode_hashtable` + `i_hash_shift` symbols. This is the
       global, comprehensive view — NOT `super_block.s_inodes`, which is
       sparse on modern kernels (only ~1 ext4 inode visible vs 13k+ via the
       hashtable on the same dump).
       1. Read inode_hashtable → pointer to `hlist_head[1 << i_hash_shift]`
       2. For each bucket, walk the hlist via inode.i_hash (hlist_node @ 0xd0)
       3.   For each inode found:
              inode.i_ino / i_size / i_mode → metadata
              inode.i_sb → superblock → fs name
              inode.i_dentry.first → container_of(dentry, d_u) → dentry_to_path
                                     with the mount's vfsmount as context →
                                     full GLOBAL path
              inode.i_data.i_pages (xarray) → cached pages

   (b) `super_blocks` → `s_inodes` walk  ← fallback
       If the hashtable symbols are missing, walk every superblock's
       `s_inodes` list. Sparse on modern kernels, but symbol-cheap.

   (c) SYMBOL-FREE fallback  ← BTF-only ISFs, NO kernel symbols
       When there are no kernel symbols at all (neither inode_hashtable nor
       super_blocks), the inode set is harvested structurally, as the UNION
       of two walks rooted at things we can reach from init_task:
         • per-process fd-table walk: for each task,
             task → files → fdt → fd[] → f_inode
           (every inode any live process holds open), AND
         • a dcache tree walk that descends from filesystem roots harvested
           via those open files' `vfsmount.mnt_root`:
             ≥ 6.8 : d_children / d_sib
             ≤ 6.7 : d_subdirs / d_child
           This pulls in cached dentries (and their inodes) that no fd
           currently references. This is how /fs is populated with no
           kernel symbols.

C) Page reassembly (recover_file)
   For each cached folio in inode.i_data.i_pages:
      walk xarray recursively (leaf = folio*, internal = xa_node*)
      PFN = (folio_va - vmemmap_base) / sizeof(struct page)  (64 B)
      PA  = PFN << PAGE_SHIFT                                (PAGE_SHIFT = 12)
      eng.phys().read(PA, buf, 4096) → write at folio.index * 4096
   Final size = min(inode.i_size, last_index*4096+4096)
```

When at least one content page is present, the reconstructed byte stream keeps
the logical file size from `inode.i_size`. Missing ranges inside that partially
cached file are zero-filled for mount and `cat` compatibility, but those zeros
are synthetic. When an inode has a path and size but **zero** cached content
pages, `/fs` returns an explicit `unavailable` explanation instead of a fake
all-zero file. Use `/sys/pagecache/recovery.txt` for fast gap-confidence triage
before treating any zero-filled range as evidence.

### Symbol-free `vmemmap_base` derivation (the v0.31 fix)

Page reassembly hinges on one constant: `vmemmap_base`, the virtual base of
the `struct page` array, used to turn a folio VA back into a PFN. Normally it
comes from a kernel symbol — but a BTF-only ISF has no such symbol, which is
exactly why content recovery used to fail on those dumps.

v0.31 derives it **symbol-free**. On x86_64 with `CONFIG_RANDOMIZE_MEMORY`:

- The vmemmap region base is **1 GiB-aligned**, and `struct page`s sit at
  `vmemmap_base + PFN * 64`.
- For RAM < 64 GiB, every cached folio's `struct page` lies within the first
  1 GiB of the vmemmap region. So the **smallest cached folio VA, rounded
  down to 1 GiB, recovers the base exactly**:

  ```
  0xfffff82b41e5b640 & ~0x3fffffff == 0xfffff82b40000000   ← derived vmemmap_base
  ```

- A wrong guess is **self-evidently** wrong: it can only yield out-of-range
  PAs, which read back as zeros. It never produces plausible garbage, so a
  bad derivation degrades to "no content recovered", never to corrupt content.

Result: file content recovers even on BTF-only dumps. Verified through the
WinFsp mount — the `/home/ubuntu/Downloads/avml` binary recovered as a valid
ELF (correct `\x7fELF` magic at offset 0) with **no kernel symbols loaded at
all**, the derived `vmemmap_base` driving every folio → PFN translation.

## Validation (Ubuntu 24.04 / kernel 6.14.0-36-generic test dump)

**Mount results — measured against an actual WinFsp mount, browsed via `ls /m/fs/`:**

```
M:\fs\
    bin  boot  dev  etc  home  lib  lib64  media  mnt  opt
    proc  root  run  sbin  snap  srv  swap.img  sys  tmp  usr  var
```

**Per-fs inode counts via inode_hashtable (definitive view):**

| Filesystem | Inodes recovered | Notes |
|------------|------------------|-------|
| ext4       | 13,448           | The real root fs from `/dev/sda2`. Via `s_inodes` we got 1. |
| cgroup2    | 3,851            | `/sys/fs/cgroup/...` |
| sysfs      | 3,574            | `/sys/...` |
| squashfs   | 3,151            | Across the 9 mounted snap squashfses |

**Sample byte-exact file recoveries (tested via the actual mount):**

| File on Linux                              | Cached pages | Size      | Recovered |
|--------------------------------------------|--------------|-----------|-----------|
| `/usr/lib/os-release` (squashfs)           | 1 / 1        | 177 B     | ✅ byte-exact |
| `/usr/lib/snapd/info` (squashfs)           | 1 / 1        | 116 B     | ✅ byte-exact |
| `/usr/lib/locale/C.utf8/LC_ADDRESS`        | 1 / 1        | 127 B     | ✅ byte-exact |
| `/usr/bin/bash` (squashfs)                 | 35 / 341     | 1.4 MB    | ✅ sparse: cached pages recovered, gaps zero-filled |
| `/usr/lib/firefox/omni.ja`                 | 509 / 10803  | 44 MB     | ✅ sparse |
| `/home/ubuntu/Downloads/avml`              | 854 / 1742   | 7.1 MB    | ✅ valid ELF header at offset 0 |
| `/home/ubuntu/Downloads/output.lime.compressed` | 10113 / 10113 | 41 MB | ✅ recovered (the dump file itself, cached during AVML capture) |
| `/run/systemd/resolve/stub-resolv.conf`    | 1 / 1        | ~1.5 KB   | ✅ byte-exact |

Sparse table rows mean MemNixFS recovered the resident cached pages and filled
missing logical ranges with synthetic zeros for stream compatibility. Check
`/sys/pagecache/recovery.txt` for fast gap-confidence triage before using zeros
as evidence.

## Caveat: resident pages only (inherent to memory forensics)

Under **any** mode, symbol-rich or symbol-free, you can only recover the
pages that were **resident in RAM at capture time**. Reclaimed or never-faulted
(non-resident) pages cannot be recovered. If some pages are resident, missing
ranges in the VFS stream are synthetic zeros; if no content pages are resident,
the `/fs` file reports `unavailable` when opened. This is not a defect: a
memory image simply does not contain pages the kernel had evicted, and there is
no amount of symbol fidelity or `vmemmap_base` cleverness that can conjure them
back. It is the same constraint every memory-forensics tool lives under.
`/sys/pagecache/recovery.txt` records fast catalog-level confidence from inode
size and cached page counts. Exact physical dropped-page checks are performed by
actual file recovery and log/journal consumers.

What is **always** accurate, even when a file's content pages are gone:

- the `/fs/` tree shape (which files/dirs exist), and
- file **sizes**, which come from inode metadata (`i_size`), not from how many
  pages happened to be cached.

So a file can show its true size yet recover only partially, or report
`unavailable` when no content pages survived. That means the bytes were not
resident in memory at capture time; it is not evidence that the original file
contained zeros.

## Known limitations

1. ~~**Mount-point composition.**~~ ✅ Done in v0.3 — see
   `src/os/linux/mountinfo.cpp`. The `/fs/` tree now shows global paths
   like `/snap/core22/2045/usr/bin/bash`, `/run/systemd/resolve/stub-resolv.conf`.

2. **Native symlink nodes.** `/fs/` currently exposes symlinks as small
   text files. MemNixFS tries to recover the target first from
   `inode.i_link`, then from cached symlink file content. If neither is
   recoverable, the text file says exactly why the target is unavailable.
   A later VFS layer can expose these as native symlink nodes.

3. **Order-N folios.** Modern kernels can allocate compound pages (folios)
   of order > 0 (huge pages, large folios). The xarray slot for such a folio
   covers `2^order` contiguous file pages; we currently treat each slot as a
   single page. For files where THP is in use, some pages may be missing.

4. **Anonymous inodes.** Sockets, pipes, anon_inode files, mqueue, etc. have
   `inode.i_dentry == NULL` — skipped for the `/fs/` tree, listed as `(anon)`
   in the pagecache catalog.

5. ~~**Deleted-but-open files.**~~ ✅ Done in v0.7. We read `i_state` and
   label entries under `/files/by-ino/` as `deleted-<fs>-<ino>.bin`
   (`I_FREEING`/`I_WILL_FREE` set) or `orphan-<fs>-<ino>.bin` (no path
   for other reasons). The content recovery itself is unchanged.

## Doing it yourself

**Preferred — mount and browse:**
```
memnixfs --dump foo.lime mount M:
explorer M:\fs                              ← reconstructed root filesystem
explorer M:\fs\snap\core22\2045\usr\bin     ← snap binaries at global path
explorer M:\fs\run\systemd\resolve          ← stub-resolv.conf etc
```

**CLI smoke tests (mounting is the primary UX, but `cat` is handy for scripts):**
```
# What mounts are there?
memnixfs --dump foo.lime cat /sys/mountinfo

# Catalogue
memnixfs --dump foo.lime cat /sys/pagecache/index.txt

# Pull a file at its real global path
memnixfs --dump foo.lime cat /fs/usr/lib/os-release
memnixfs --dump foo.lime cat /fs/snap/core22/2045/usr/lib/os-release

# Or by inode number (forensic fallback for deleted-but-cached files)
memnixfs --dump foo.lime cat /files/by-ino/squashfs-2629.bin

# Stream the FULL physical image. The AVML reader now presents physical
# memory as a contiguous sparse image — interior sparse gaps come back as
# zeros rather than stopping the stream at the first gap.
memnixfs --dump foo.lime cat /mem/phys.raw > phys.raw
```

## ISF symbols & types required

| Symbol             | Used for                           | If absent |
|--------------------|------------------------------------|-----------|
| `inode_hashtable` + `i_hash_shift` | tier-(a) global inode walk | fall back to tier (b), then tier (c) |
| `super_blocks`     | head of mounted-fs linked list (tier b) | fall back to tier (c) fd-table + dcache walk |
| `vmemmap_base`     | folio_va → PFN translation         | **derived symbol-free** (see above) |

| Struct             | Fields used                        |
|--------------------|------------------------------------|
| `super_block`      | `s_list`, `s_inodes`, `s_type`, `s_id` |
| `inode`            | `i_mode`, `i_sb`, `i_mapping`, `i_ino`, `i_size`, `i_state`, `i_sb_list`, `i_dentry`, `i_data` |
| `address_space`    | `i_pages`, `nrpages`               |
| `xarray`           | `xa_head`                          |
| `xa_node`          | `shift`, `slots`                   |
| `folio`            | `index` (optional)                 |
| `file_system_type` | `name`                             |
| `dentry`           | (full set — shared with fdtable)   |

On a symbol-rich ISF all of the above come from the standard Volatility-3 JSON
and no extra fetching is required. On a **BTF-only ISF** none of the symbols
exist — inode enumeration falls through to the symbol-free tier (c) and
`vmemmap_base` is derived, so /fs and file content still recover.

## Where this fits in MemProcFS / vol3 parity

| Tool we mirror              | Their equivalent                            |
|-----------------------------|---------------------------------------------|
| `/sys/pagecache/index.txt` | vol3 `linux.pagecache.Files` plugin output |
| `/files/by-ino/`            | vol3 `linux.pagecache.InodePages --inode N` |
| `/fs/` (global root recon.) | vol3 `linux.pagecache.RecoverFs --output-dir …` |
| `/sys/mountinfo`       | live `/proc/mountinfo`                      |
| (planned: filescan-style)   | vol3 `linux.pagecache.Files --pid …`        |
