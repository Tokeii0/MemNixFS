# Process views (`/sys/processes/`)

**Status:** v0.6 — pslist + pstree + psaux all live.
**Source:** `src/os/linux/process_views.{h,cpp}`
**Engine wiring:** `src/vfs/sys_module.cpp`
**Cross-ref:** vol3 `linux.pslist`, `linux.psaux`, `linux.pstree`;
MemProcFS `m_sys_proc.c`.

---

## Why these exist

The canonical process list is already in `/proc/<pid>-<comm>/` — every
process the kernel sees via `init_task.tasks` gets its own directory.
But that's a flat directory listing, not a useful triage view.

`/sys/processes/` adds three text renderings of the same data:

| File | Shape | Best for |
|------|-------|----------|
| `pslist.txt` | flat, sorted by appearance | `grep`-ing for known PIDs / cmdline patterns |
| `pstree.txt` | hierarchical by `ppid` | "how did this process get there?" |
| `psaux.txt`  | flat + VSZ + cmdline | "what's running and what command line did it run?" |

All three walk the same `Engine::processes()` list — they're **pure
formatters**, no extra kernel reads.

## pslist.txt

```
# Total: 331 processes
#
#    PID   PPID   TGID    UID  COMM              CMD
# ------ ------ ------ ------  ----------------  ------------------------
       1      0      1      0  systemd           /sbin/init splash
       2      0      2      0  kthreadd          [kthreadd]
       3      2      3      0  pool_workqueue_   [pool_workqueue_]
     ...
    4849   4839   4849   1000  bash              bash
    4897   4849   4897   1000  sudo              sudo ./avml --compress output.lime.compressed
    4899   4898   4899      0  avml              ./avml --compress output.lime.compressed
```

Kernel threads are shown with the comm in brackets (the `ps` convention),
matching what you'd see on a live box.

## pstree.txt

```
+-- 1 systemd
|   +-- 442 systemd-udevd
|   +-- 1652 gnome-session-b
|   |   +-- 2045 firefox
|   |   |   +-- 3096 firefox
|   |   |   \-- 4690 Web Content
|   |   \-- 4839 gnome-terminal-
|   |       \-- 4849 bash
|   |           \-- 4897 sudo
|   |               \-- 4898 sudo
|   |                   \-- 4899 avml
\-- 2 kthreadd
    +-- 3 pool_workqueue_
    +-- 4 kworker/R-rcu_g
    ...
```

Drawn with ASCII connectors (`+--`, `\--`, `|`) so the output stays
readable in classic `cmd.exe` and copy-pastes cleanly. Real Unicode
box-drawing chars also work in modern Windows Terminal but we chose
ASCII for the broadest compatibility.

The roots are processes whose `ppid` isn't another visible process (so
`pid 1 systemd` and `pid 2 kthreadd` typically; sometimes `pid 0` for
swapper if it appeared in the list).

## psaux.txt

```
     PID   PPID    UID       VSZ_KB  COMM              USER              CMD
     ---   ----    ---       ------  ----              ----              ---
    3096   2045   1000      4341792  firefox           uid=1000          /snap/firefox/7423/usr/lib/firefox/firefox
    4690   3277   1000      3474632  Web Content       uid=1000          /snap/firefox/7423/usr/lib/firefox/firefox -contentproc ...
    4849   4839   1000        11368  bash              uid=1000          bash
    4897   4849   1000        19812  sudo              uid=1000          sudo ./avml --compress output.lime.compressed
    4898   4897   1000        19812  sudo              uid=1000          sudo ./avml --compress output.lime.compressed
    4899   4898      0         7168  avml              uid=0             ./avml --compress output.lime.compressed
```

VSZ is the sum of every VMA size (in KiB) — same definition `ps`
reports. We don't compute `%CPU`/`%MEM` because they require time deltas
that a single snapshot doesn't have.

The USER column shows `uid=N` numerically; UID-to-name resolution against
the cached `/etc/passwd` is future work (the standalone `/sys/users.txt`
view already provides the UID → name table).

## What's NOT here yet (deferred)

- ~~**Per-thread enumeration.**~~ ✅ Done in v0.11. See
  `/proc/<pid>/threads.txt` and `/sys/processes/threads.txt`. 890 threads
  across 331 leaders on the Ubuntu test dump.
- **UID → username** in psaux. We have the data path (read `/etc/passwd`
  from the page cache or walk `init_user_ns`), just haven't wired it up.
- **`linux.pidhashtable`-style enumeration.** A third independent
  process source (kernel `pid` xarray). Would strengthen the
  psscan-style cross-view diff.

## How this relates to `/sys/findevil/psscan.txt`

`psscan` is a SECONDARY check, not the canonical list. It exists to
catch things the canonical walk would miss:

- threads (we don't list them under /proc/)
- DKOM-rootkit-unlinked tasks
- recently-exited processes whose slab page is still cached

The header of `psscan.txt` now spells this out so analysts don't read
"463 candidates vs 331 visible" as suspicious — most of the gap is
threads.

## Preloading

These views (`pslist`, `pstree`, `psaux`, `threads`, plus the `.csv`/`.json`
siblings) are tagged `system-info` in the [forensic warmer](forensic-mode.md),
so **every** `--forensic` mode — including the default `smart` — pre-warms them
in the background. Opening `/sys/processes/*` after a `--forensic` (or
`--precompute`) mount is instant, and the listing shows real sizes up front.
Without warming they compute on first open (a single pass over the
already-enumerated process list — fast).
