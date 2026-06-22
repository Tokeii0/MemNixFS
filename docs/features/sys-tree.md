# /sys/ — System-wide views

`/sys/` mirrors MemProcFS's system-wide module set (`m_sys_*`) and
Volatility 3's "system" plugins. Each file is a different kernel-level
view of the dump. Use `/sys/` for system-wide views.

## Files in `/sys/`

Gap-confidence files: `pagecache/recovery.txt` records fast per-file
gap-confidence from inode size and cached page counts, and `mem_ranges.txt`
lists captured physical ranges when the dump format exposes them. Sparse
zero-fill in VFS streams is not evidence unless the relevant exact recovery
consumer reports `checked`.

FindEvil now exposes normalized ranked indicators at
`/sys/findevil/indicators.{txt,csv,json}` in addition to the detailed check
files. Timeline output is split under `/forensic/timeline/` into `all`,
`process`, `network`, `shell`, `kernel`, and `findevil` text/CSV pairs while
keeping the legacy `/forensic/timeline.{txt,csv}` files.

| File | Status | Source |
|---|---|---|
| `banner.txt` | ✅ | `src/vfs/sys_module.cpp` — `linux_banner` via kernel PGD |
| `dtb.txt` | ✅ | DTB scan diagnostics + KASLR shifts + init_task PA/VA |
| `kallsyms` | ✅ | Full kernel symbol table (`/proc/kallsyms` format) |
| `btf.txt` | ✅ | BTF blob diagnostics |
| `modules/<name>/info.txt` | ✅ | Walks kernel `modules` list; per-module memory layout, version, srcversion, args |
| `dmesg` | ✅ | printk ring buffer (`prb`) — see below |
| `pagecache/index.txt` | ✅ | Every cached inode across every mounted fs — see [pagecache.md](pagecache.md) |
| `mountinfo` | ✅ | Every mount in init namespace, /proc/mountinfo format |
| `shell_history.txt` | ✅ | Aggregate bash/zsh/fish/POSIX shell history with source tags, PID/UID, timestamp when known, and sectioned confidence grouping |
| `crash/{summary.txt,events.txt,call_traces.txt}` | ✅ | Crash/failure evidence triage from recovered dmesg and cached logs; missing sources are reported as unavailable, not as proof of no crash |
| `journal/{index.txt,text_logs.txt,journald.txt}` | ✅ | Cached syslog/journald/filesystem-journal candidates with explicit checked/partial/unavailable states |
| `net/{tcp,udp,interfaces,summary.txt}` | ✅ | Network state — see [network.md](network.md) |
| `findevil/{triage,findevil,malfind,psscan,hidden_modules,check_syscall,tty_check,keyboard_notifiers,check_idt,check_afinfo,check_creds,check_modules,ebpf,entropy,modxview,kprobes}.txt` + CSV siblings | ✅ | Threat-hunt — ranked triage view, **14 plugins**, aggregator, and SIEM CSV. See [findevil.md](findevil.md) |
| (top-level) `/forensic/timeline.{txt,csv}` and `/forensic/timeline_summary.txt` | ✅ | One absolute-UTC stream: **file MAC times** (inode m/ctime) + process starts + dmesg + multi-shell history + eBPF + crash/log. Boot-relative rows anchored to wall-clock via the kernel timekeeper (`xtime_sec−ktime_sec`; boot-relative fallback on pure-BTF dumps); undated socket/FindEvil snapshots trail the end. Plus a high-signal summary |
| `processes/pslist.csv`, `net/{tcp,udp}.csv` | ✅ | RFC 4180 CSV siblings for SIEM ingest |
| `processes/{pslist.txt,pstree.txt,psaux.txt}` | ✅ | `ps`-style text views of the canonical process list — see [process-views.md](process-views.md) |
| `cpuinfo` | ✅ | `boot_cpu_data` — `src/os/linux/sysinfo.cpp` |
| `meminfo` | ✅ | `totalram_pages` × 4 KiB — `src/os/linux/sysinfo.cpp` |
| `iomem` | ✅ | `iomem_resource` tree — `src/os/linux/sysinfo.cpp` |

## File-by-file detail

### `banner.txt`
The kernel's `linux_banner` string, read via the kernel-VA page table
walker. This is a smoke test for DTB validation: if `banner.txt`
returns the real banner, kernel-VA → PA translation works for everything
else (kallsyms-stack walking, module enumeration, etc.).

```
$ cat /mnt/M/sys/banner.txt
Linux version 6.14.0-36-generic (buildd@lcy02-amd64-067) (x86_64-linux-gnu-gcc-13 …) #36~24.04.1-Ubuntu SMP PREEMPT_DYNAMIC …
```

When DTB validation fails (no `init_top_pgt` symbol, brute-force scan
finds no PGD that walks back to the banner, etc.) this file falls back
to the directly-scanned banner from physical memory and tells you so:

```
Linux version 6.14.0-36-generic ...
# note: kernel-VA linux_banner read unavailable; DTB did not validate
# (strategy=banner-anchored). Banner above was recovered by physical scan.
```

### `dtb.txt`
Diagnostics for the DTB resolver. Useful when something downstream
(kallsyms-stack walking, module enumeration) fails — the first thing
to check is whether the DTB is validated.

```
dtb_pa:        0x0000000014747000
validated:     true
strategy:      brute-force
kaslr_phys:    0xa6800000
kaslr_virt:    0xa6800000
init_task_pa:  0x000000002420c000
init_task_va:  0xffffffffaee10f00
direct_map_base:0xffff8a0d80000000
```

| Field | Meaning |
|---|---|
| `dtb_pa` | PA of the kernel's current PGD root |
| `validated` | `true` if the DTB walks back to the banner correctly |
| `strategy` | Which DTB-finding strategy won: `banner-anchored`, `init_task-anchored`, or `brute-force` |
| `kaslr_phys/virt` | KASLR shifts. Positive = kernel relocated up |
| `init_task_pa/va` | Where init_task lives (PA from swapper scan, VA = static + shift) |
| `direct_map_base` | Kernel direct-map base VA. PAs are accessed via `direct_map_base + pa` |

### `kallsyms`
**This is the big one.** A byte-for-byte `/proc/kallsyms`-compatible
listing of every kernel symbol:

```
ffffffff9b000000 T _text
ffffffff9b000000 T _stext
ffffffff9b001000 T page_offset_base
ffffffff9b001010 T __init_begin
ffffffff9b001010 T phys_base
ffffffff9b001020 D init_task
ffffffff9bed7a20 D linux_banner
ffffffff9c810940 D modules
…
```

135k–210k lines depending on the kernel. Same format the running kernel
exposes through `/proc/kallsyms`, so:

- `perf` can ingest it for backtrace symbolisation
- `drgn` can use it for debugger-style queries
- `bcc` / `bpftrace` reference symbols by name from it
- `awk` / `grep` / `cat` / custom scripts work unchanged

```powershell
# Find all `do_*_module` functions
type M:\sys\kallsyms | findstr /R "T do_.*_module"

# Resolve a specific symbol
type M:\sys\kallsyms | findstr "T init_task"
```

### `dmesg`
The kernel's printk ring buffer (`/proc/kmsg` / `dmesg -k` equivalent).
Modern (≥ 5.10) kernels store this in `struct printk_ringbuffer`
(`prb` global), with a separate descriptor ring + info ring + text
data ring. We walk all three and format each finalized record:

```
$ cat /mnt/M/sys/dmesg | head -5
[    0.000000] <2>Linux version 6.14.0-36-generic (buildd@lcy02-amd64-067) ...
[    0.000000] <2>Command line: BOOT_IMAGE=/boot/vmlinuz-6.14.0-36-generic ...
[    0.000000] <2>KERNEL supported cpus:
[    0.000000] <2>  Intel GenuineIntel
[    0.000000] <2>  AMD AuthenticAMD
```

Format: `[<sec>.<usec>] <<level>> <message>`. Levels are the standard
printk levels (0=emerg, 1=alert, 2=crit, 3=err, 4=warn, 5=notice,
6=info, 7=debug).

`src/os/linux/dmesg.cpp` implements three translation strategies for
reading the ringbuffer's internal pointers (which on modern kernels
with resized log_buf point into kmalloc'd direct-map memory):

1. **Direct-map VA** → subtract `direct_map_base` (kmalloc'd memory).
2. **Kernel-image VA** → translate via `kaslr_phys_shift` (static
   `printk_rb_static` and its embedded arrays).
3. **PGD walk** → full kernel page-table walk (fallback when DTB is
   validated).

This means dmesg works even on dumps where DTB resolution failed
(image-relative and direct-map both bypass the page tables).

Tested:
- Ubuntu 6.14.0-36-generic (AVML) → **1,705 lines** of dmesg
- Alpine 6.12.1-3-virt (raw)       → **376 lines** of dmesg

### `pagecache/index.txt` and the `/files/` tree

The catalog of every inode the kernel page cache currently knows about,
across every mounted filesystem. The companion `/files/` tree exposes
each inode's *cached pages reassembled in file order* as an actual file
you can `cat`, `copy`, `grep`, or open in a hex editor.

This is the killer feature for forensics where you need to see files
that have been touched but are no longer held open by any process:
attacker scripts, ephemeral configs, deleted-but-cached binaries, log
tails that haven't been flushed yet.

See the dedicated page: **[pagecache.md](pagecache.md)**, and the
recipe: [recipes/extract-files-from-memory.md](../recipes/extract-files-from-memory.md).

### `crash/` and `journal/`

`/sys/crash/` summarizes recovered crash/failure evidence from dmesg and any
cached syslog-style logs. It flags kernel panics, oops/BUG traces, lockups,
OOM, I/O errors, and filesystem/journal abort messages when those strings are
present in recovered sources.

`/sys/journal/` indexes cached log and journal candidates. If journald or
syslog files were not resident in page cache, the files say `unavailable`
rather than implying the system had no crash. Filesystem consistency checks are
also conservative: inode/bitmap validation is `unverified` unless the needed
filesystem metadata was recovered and parsed.

See [crash-journal.md](crash-journal.md).

### `btf.txt`
Diagnostics for BTF detection:

```
available:   yes
offset_pa:   0x000000000023a494d0
size_bytes:  6739469
version:     0x10000
; Offline symbol generation from this BTF is in use:
; the engine extracted it and merged with kallsyms to synthesise an ISF.
```

If no BTF is found:

```
; no BTF detected in dump
; (kernel was likely built without CONFIG_DEBUG_INFO_BTF=y, OR
;  the BTF blob is past our scan range)
```

## How files are populated

Each file is a **`LazyFileNode`** — its content is generated on first
read, not when the tree is built. Listing `/sys/` is free; reading
`/sys/kallsyms` triggers extraction (which is already cached on the
Engine, so it's a memcpy + format, not a re-scan).

```cpp
// src/vfs/sys_module.cpp
root->add(std::make_shared<LazyFileNode>("kallsyms", [engp]() -> ByteBuf {
    const auto& k = engp->kallsyms();   // already extracted at startup
    std::string out;
    for (const auto& e : k.symbols) {
        fmt::format_to(std::back_inserter(out),
                       "{:016x} {} {}\n", e.address, e.type, e.name);
    }
    return ByteBuf(out.begin(), out.end());
}));
```

## Adding a new `/sys/` file

Every file here — `modules/`, `dmesg`, `mounts`, `cpuinfo`, etc. —
follows the same pattern: add a `LazyFileNode` (or `DirNode`) to
`sys_module.cpp`, and write a producer in `src/os/linux/*` that returns
the right `ByteBuf`.
