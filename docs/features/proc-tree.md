# /proc/&lt;pid&gt;/ — Per-process files

Each running process appears as a directory in the mounted VFS:

```
/proc/1-systemd/
/proc/2-kthreadd/
/proc/4849-bash/
…
```

Directory name is `<pid>-<comm>` (matching MemProcFS's convention).
This makes `/proc/<TAB>` autocomplete in Explorer / shells more useful
than just numeric PIDs.

## Files in each directory

| File | Format | Status | Source |
|---|---|---|---|
| `info.txt` | Custom — quick-look summary | ✅ | `src/vfs/proc_module.cpp` |
| `memmap.txt` | Custom — VMA list with sizes/files | ✅ | `src/os/linux/task_files.cpp` |
| `cmdline` | NUL-separated argv | ✅ | `src/os/linux/task_files.cpp` |
| `environ` | NUL-separated env | ✅ | same |
| `comm` | The 16-char `task->comm` | ✅ | same |
| `status` | `/proc/PID/status` subset (Name, Umask, State, Tgid, Pid, PPid, Uid, Gid) | ✅ | same |
| `stat` | `/proc/PID/stat` 52-field format (works with `ps`) | ✅ | same |
| `statm` | `/proc/PID/statm` (memory usage in pages) | ✅ | same |
| `limits` | `/proc/PID/limits` (full rlimit table with names + units) | ✅ | same |
| `loginuid` | The `loginuid` field as a single integer | ✅ | same |
| `oom_score_adj` | OOM-killer adjustment as a signed integer | ✅ | same |
| `exe` | Resolved path of the executable | ✅ | same |
| `cwd` | Resolved current working directory | ✅ | same |
| `root` | Resolved root directory (for chrooted processes) | ✅ | same |
| `maps` | Byte-exact `/proc/PID/maps` format | ✅ | `src/os/linux/task_files.cpp` |
| `capabilities` | Inh/Prm/Eff/Bnd/Amb cap masks | ✅ | same |
| `proc.dmp` | ELF64 core dump of the process's mapped memory | ✅ (streaming) | `src/os/linux/elf_core_stream.cpp` |
| `fd_table.txt` | Open fds with mount-resolved paths AND socket cross-reference (`socket:TCP 192.168.x.x:Y -> Z:443 ESTABLISHED`, `socket:UNIX path=/run/...`, `socket:NETLINK proto=N`) | ✅ | `src/os/linux/fdtable.cpp` + `netstat.cpp` |
| `shell_history.txt` | Bash/zsh/fish/POSIX history candidates with source tags and confidence sections | ✅ | `src/os/linux/bash_history.cpp` |
| `malfind.txt` | Suspicious VMAs (RWX anonymous, exec stack, JIT pages) | ✅ | `src/os/linux/findevil.cpp` |
| `entropy.txt` | Shannon entropy of every EXEC VMA (≥ 7.0 = packed/encrypted) | ✅ | `src/os/linux/entropy.cpp` |
| `kstack.txt` | Symbolised kernel-stack walk — kallsyms-resolved return addresses | ✅ | `src/os/linux/pscallstack.cpp` |
| `threads.txt` | All threads of this thread-group (TID / state / comm) | ✅ | `src/os/linux/threads.cpp` |
| `libs.txt` | Shared libraries grouped by resolved path | ✅ | `src/os/linux/task_extras.cpp` |
| `ptrace.txt` | Tracer + tracees (real_parent vs parent + victim list) | ✅ | `src/os/linux/task_extras.cpp` |
| `wchan` | Current syscall the process is sleeping in | ⛔ future (needs kallsyms-stack-walker) | — |
| `threads/<tid>/` | Per-thread folders (stat, status, stack, regs) | ⛔ future | future work |

## File-by-file detail

### `info.txt`
Quick triage data:
```
PID:        4849
TGID:       4849
PPID:       4839
UID:        1000
GID:        1000
COMM:       bash
TASK_VA:    0xffff8a0d819d0a00
MM:         0xffff8a0d81234000
VMA_COUNT:  31
USERMEM_KB: 956
```

### `memmap.txt`
Human-readable VMA list (alternative to the strict `maps` format):
```
[001] vm_start=0x55c0d1a00000 vm_end=0x55c0d1a06000 size=6 KiB  perm=r--p  file=/usr/bin/bash
[002] vm_start=0x55c0d1a06000 vm_end=0x55c0d1afa000 size=976 KiB perm=r-xp  file=/usr/bin/bash
…
```

### `cmdline`, `environ`
Read from `mm->arg_start..arg_end` and `mm->env_start..env_end`
respectively via the user PGD. NUL-separated tokens just like the real
/proc. If recovery fails, environ explains whether the process is a kernel thread, the `mm_struct` or user PGD was unreadable,
the environment range was empty, or the range was non-resident.

### `comm`
The 16-byte `task_struct.comm` field, NUL-trimmed and newline-terminated.

### `status`
```
Name:   bash
Umask:  0022
State:  S (sleeping)
Tgid:   4849
Pid:    4849
PPid:   4839
Uid:    1000   1000   1000   1000
Gid:    1000   1000   1000   1000
```

Subset of the kernel's `/proc/PID/status` output — the most-used fields.

### `stat`
The 52-field whitespace-separated single-line format that `ps` and
`top` parse. Validated to work with `ps --pid <X> -o pid,comm,stat,etime`.

### `maps`
**Byte-exact `/proc/PID/maps` format** — every line is:
```
<start>-<end> <perms> <pgoff> <dev_major>:<dev_minor> <inode>   <pathname>
```

Cross-checked against `vol linux.proc.Maps --pid 4849` output on the
test dump: every line matches, including `pgoff` (page offset within
the mapped file).

### `proc.dmp`
ELF64 core. See [VMAs & memory](vma-and-memory.md). Streamed —
opening this file in HxD / FTK Imager / `dd` / `xxd -s` doesn't
materialise it in RAM.

### `exe`, `cwd`, `root`
Path-resolution walks `task->mm->exe_file` / `task->fs->pwd` /
`task->fs->root` via `dentry_path()`-style chained `d_parent` walk to
the mount root. Output is a single line with the resolved path.

### `capabilities`
```
CapInh: 0000000000000000
CapPrm: 00000003fffffeff
CapEff: 00000003fffffeff
CapBnd: 00000003fffffeff
CapAmb: 0000000000000000
```

Masks read from `task->cred->cap_inheritable / permitted / effective /
bset / ambient`.

## Performance notes

### Lazy population
Listing the proc tree (`tree` command, or just browsing `M:\proc\` in
Explorer) does NOT read any of these files — only their names are
materialised. File contents are produced on first read.

### Streaming `proc.dmp`
Even when the file IS read, `proc.dmp` is streamed: a `dd if=…
skip=… count=…` for a specific range only reads the VMAs that cover
it, with one user-PGD walk per page (and 99% cache hit rate on
sequential reads). No memory pressure.

### Order
Processes are listed in PID order (which is task-list-walk order). This
is the order they appear on a running system — kernel threads first
(low PIDs), then user processes by creation time.

## Reference

- MemProcFS: `vmm/modules/m_proc.c` (registers per-PID directories),
  `m_misc_procinfo.c` (info.txt-equivalent), `m_proc_memmap.c` (VMA
  files), `m_proc_minidump.c` (process dump file)
- Volatility 3: `proc.Maps`, `envars.py`, `psaux.py`, `elfs.Elfs`,
  `capabilities.py`
- Kernel source: `fs/proc/base.c` (most `/proc/PID/...` files),
  `fs/proc/task_mmu.c` (`maps`)
