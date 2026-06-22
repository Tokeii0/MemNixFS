# Threat-hunt heuristics (findevil)

**Status:** malfind + psscan + hidden_modules + 11 kernel-integrity checks
(14 checks total), all working on the clean Ubuntu test dump (0 kernel-level
findings). malfind
excludes vDSO/signal noise and surfaces RX-anon (post-`mprotect` payloads), with
a content peek per region; the verdict is kernel-level-only and anon-exec is
always surfaced in a `REVIEW:` line.
**Source:** `src/os/linux/findevil.{h,cpp}`
**Engine wiring:** `src/vfs/sys_module.cpp` (`/sys/findevil/`),
`src/vfs/proc_module.cpp` (`/proc/<pid>/malfind.txt`)
**Cross-ref:** vol3 `linux.malfind`, `linux.psscan`,
`linux.hidden_modules`; MemProcFS `m_evil_proc1.c`, `m_evil_kernproc1.c`,
`m_fc_findevil.c`.

---

## What we expose

The primary FindEvil entry points are now `triage.txt` and
`indicators.{txt,csv,json}`. The indicator files carry severity, confidence,
type, evidence, false-positive context, and next-step paths. The older detailed
check files remain available for drill-down.

```
M:\sys\findevil\
    triage.txt           ← ranked analyst entry point with process context
    indicators.txt       ← normalized ranked indicators (severity/confidence)
    indicators.csv       ← same rows, RFC 4180 for SIEM ingest
    indicators.json      ← same rows, machine-readable
    findevil.txt         ← aggregated verdict + anon-exec REVIEW line
    malfind.txt          ← anon-exec regions (vDSO excluded; RX-anon surfaced)
    psscan.txt           ← physical-memory task_struct scan
    hidden_modules.txt   ← kallsyms-vs-module-list cross-view
    check_syscall.txt    ← sys_call_table integrity (#1 rootkit detector)
    tty_check.txt        ← tty_operations vtable audit (keylogger detector)
    keyboard_notifiers.txt  ← notifier chain audit (keylogger detector)
    check_idt.txt        ← Interrupt Descriptor Table integrity (v0.13)
    check_afinfo.txt     ← /proc/net seq_ops vtable audit (8 protocols) (v0.13)
    check_creds.txt      ← root-cred sharing audit (v0.13)
    check_modules.txt    ← modules-list vs. mod_tree cross-view (v0.13)
    ebpf.txt             ← every loaded eBPF program (v0.14)
    tracepoints.txt      ← ftrace/tracepoint handler audit
    av_edr.txt           ← AV/EDR agent fingerprints (userspace + LKM)
    entropy.txt          ← high-entropy executable VMAs (v0.14)
    modxview.txt         ← three-source modules cross-view (v0.15)
    malfind.csv          ← RFC 4180 SIEM-ingest sibling (v0.15)
    findevil.csv         ← single-row verdict CSV (v0.15)
    kprobes.txt          ← every registered kprobe + handler audit (v0.16)

M:\forensic\
    timeline.txt         ← chronologically merged events (v0.17)
    timeline_summary.txt ← high-signal counts and timeline highlights
    timeline.csv         ← same data as CSV for SIEM ingest

M:\proc\<pid>\
    malfind.txt          ← per-process suspicious-VMA listing
```

## triage.txt — first file to open

`triage.txt` consumes the shared indicator model instead of re-running a
separate ad hoc summary. It ranks the highest-signal evidence first: hidden
task/module rows, kernel hook indicators, then userspace anonymous executable
mappings with PID, UID, `comm`, command line when readable, VMA range, content
hint, false-positive context, and a next-step path. It is a triage guide, not a
proof of clean or compromised state.

## indicators.{txt,csv,json} - normalized ranked indicators

`indicators.txt`, `indicators.csv`, and `indicators.json` expose the same
ranked rows in analyst-readable, SIEM-friendly, and machine-readable forms.
Each row has severity, confidence, type, source, process context when
available, summary, evidence, false-positive context, and the next VFS path to
inspect.

Severity is intentionally conservative. Strong hidden-object evidence, kernel
function-pointer hooks, and clear RWX/exec-stack injection markers can become
`HIGH`. JIT-like executable memory, tracing eBPF, shell/admin tools, and network
tool socket ownership stay `REVIEW` or `INFO` unless they correlate with
stronger evidence.

## findevil.txt — aggregated verdict (single source of truth)

```
malfind:         47 anon-exec region(s) across 15 process(es); 31 RWX/exec-stack
                 marker(s) across 14 process(es) (vDSO/signal pages excluded;
                 RX-anon is JIT-or-injected — see REVIEW below + malfind.txt).
psscan:          463 task candidates by phys scan, 0 NOT in visible list (HIDDEN)
hidden_modules:  74 module record(s), 0 NOT in `modules` list (HIDDEN)

VERDICT: no kernel-level compromise indicators by these checks
         (heuristics — not a guarantee the box is clean).

REVIEW:  15 process(es) hold anonymous executable memory (31 RWX/exec-stack
         marker(s)). JIT runtimes (browser, node, JVM, gnome JS) trip this
         legitimately — but injected code (Meterpreter, shellcode) looks
         IDENTICAL. Open malfind.txt: a process you'd expect to JIT is fine;
         an unexpected one with non-zero anon-exec is a strong injection signal.
```

The VERDICT reflects **only unambiguous kernel-level indicators** — hooks
(syscall/IDT/tty/keyboard/afinfo/kprobe), hidden tasks, hidden modules, cred
sharing, mod-tree asymmetry. Userspace anonymous-executable memory (malfind) is
deliberately NOT folded into the verdict: it's ambiguous (every JIT runtime
trips it), so doing so would either cry wolf on a desktop or — worse — let a
real RX-anon payload be hand-waved as "clean." Instead, anon-exec is **always**
surfaced in a separate `REVIEW:` line so it can never be silently missed.

## malfind

Anonymous executable memory — the classic Linux code-injection detector.
Walks each process's maple-tree VMAs and reports the **anomalous** ones:

| Pattern | Severity | Typical cause |
|---|---|---|
| RWX + anonymous | ★ marker | injected shellcode, JIT with W^X disabled |
| executable stack | ★ marker | old toolchain or deliberate exec-stack bypass |
| anonymous r-x, > vDSO size | reported (not ★) | **JIT region OR a payload post-`mprotect(R\|X)`** (e.g. Meterpreter) — these look identical; triage by content + process |
| anonymous r-x, ≤ 2 pages | **excluded** | `[vdso]` / signal-restorer page — every process has one; pure noise, never shown |

Two deliberate design points (changed after the old output was found
misleading — it was ~30% vDSO noise and silently dismissed RX-anon as "benign
JIT," so a post-`mprotect` payload produced no row):

1. **[vdso]/signal pages are excluded entirely**, not listed as "informational."
2. **RX-anon is surfaced, not dismissed.** A reflectively-loaded payload spends
   most of its life as RX-anon (after `mprotect(PROT_READ|PROT_EXEC)`); JITs also
   produce RX-anon. They're indistinguishable by flags, so malfind reports both
   and gives you a **content peek** to triage: `non-zero [48 89 e5 …]` means the
   region holds live bytes (code/data); `zero-filled` means an empty reservation.

Output sample (`★` = RWX/exec-stack injection marker; unmarked = RX-anon to
review; the second line of each row is the content peek):

```
# 47 anon-exec region(s) across 15 process(es). Of those, 31 are ★
# injection markers (RWX-anon or executable stack) across 14 process(es);
# the rest are RX-anon (JIT engines AND post-mprotect injected payloads both
# look like this — use the 'content' hint + the process identity to triage).
# [vdso]/signal pages are EXCLUDED as benign.

=== pid 1119 (gnome-remote-de) — 3 region(s)  ★ injection marker ===
  ★ 0x0075a642b0f000 - 0x0075a642b10000  rwx      4096 B  RWX anonymous mapping — classic code injection
      non-zero [55 48 89 e5 41 57 41 56 ...]
    0x007e716ed8f000 - 0x007e716ed9f000  r-x     65536 B  anonymous executable mapping (RX) — JIT or injected code; inspect
      zero-filled (empty reservation)
```

## psscan

Walks physical memory looking for `task_struct` signatures and diffs the
result against the official `init_task.tasks` walk. Entries in the scan
but not in the official list are "hidden" — typical rootkit behaviour.

### Algorithm

1. Slide a window through every 8-byte aligned position in physical memory.
2. At each position, treat `pa + comm_off` as a candidate `task_struct.comm`
   field. Check that it's a 2+-char NUL-terminated name in the restricted
   ASCII set Linux uses (letters / digits / `_-/.:[]+@~`).
3. Cross-check with task_struct invariants at the implied positions:
   - `pid <= 0x400000` (kernel pid_max ceiling)
   - `tgid` not zero unless pid is zero
   - `mm` is 0 or a kernel pointer
   - `tasks.next` AND `tasks.prev` are kernel pointers
   - `__state` is ≤ 0x1ff (TASK_RUNNING / INTERRUPTIBLE / TRACED / DEAD bits only)
4. **Cross-validation:** `tasks.next` points to another task's `tasks`
   field. Convert via `direct_map_base` to a PA and check that THAT also
   has a plausible `comm`. This is the killer filter — random byte patterns
   that pass all prior tests almost never satisfy a real linked-list
   cross-reference too.
5. Visibility check:
   - Exact `(pid, comm)` match → visible
   - `pid == 0` and `comm` starts with `swapper/` → visible (per-CPU idle threads)
   - `tgid != pid` and `tgid` matches a known leader pid → visible (thread of a visible process)
   - Else → **HIDDEN**

Result on the test dump: **686 040 → 463 → 0 hidden** after the layered
filtering. (vol3 typically returns under 1k candidates with comparable
filtering.)

## check_syscall (v0.8)

Reads every entry of `sys_call_table` and classifies it:

| Status | Meaning |
|---|---|
| **OK**           | Entry points into kernel text AND resolves to a syscall-handler symbol (`__x64_sys_*`, `sys_*`, `__do_sys_*`, `sys_ni_syscall`, …) |
| **SUSPICIOUS**   | Entry is inside kernel text but the nearest kallsyms symbol doesn't match handler conventions |
| **★ HOOKED**     | Entry points OUTSIDE the kernel-text range `[_stext.._etext]` — unambiguous rootkit behavior |

Before any row is called hooked, MemNixFS validates that the recovered
`sys_call_table` candidate mostly contains canonical kernel function
pointers. If a LiME gap, bad translation, or symbol-recovery problem makes the
candidate read like instruction bytes or random data, the report says
`unavailable` with the exact reason instead of treating every slot as a rootkit
hook.

Table-size determination: we look at the next kallsyms symbol after
`sys_call_table` — the byte gap between them is the exact table size,
so we don't have to guess or stop at sparse NULL entries (which are
real, deliberately-unused slots).

On the clean Ubuntu test dump: **468 syscalls, 0 hooks, 0 suspicious**.
Entries resolve to canonical names like `__x64_sys_read`, `__x64_sys_write`,
`__x64_sys_open`, `__x64_sys_close`, ..., `__x64_sys_io_uring_setup`, etc.

A hooked rootkit would jump out immediately: the HOOKED rows sort to the
top and carry a one-line explanation like
"entry @ 0xffffffffc0a12345 is OUTSIDE kernel text — almost certainly hooked".
Module-loaded addresses (`0xffffffffc...`) are the classic giveaway.

## tty_check + keyboard_notifiers (v0.9)

Two classic **keylogger detectors**, sharing the same machinery as
`check_syscall`:

**tty_check** walks the kernel's `tty_drivers` linked list. For every
driver, it audits every entry in `tty_operations` (the ~37-slot vtable:
`open`, `close`, `read`, `write`, `ioctl`, `set_termios`, …). A keylogger
that intercepts terminal I/O usually hooks one of these.

```
=== ttyDBC (driver_name="dbc_serial" @ 0xffff8a0d…, ops @ 0xffffffffa7f4cf40) ===
  install             OK           0xffffffffa78c0230  dbc_tty_install
  open                OK           0xffffffffa78c01f0  dbc_tty_open
  close               OK           0xffffffffa78c01b0  dbc_tty_close
  write               OK           0xffffffffa78c0630  dbc_tty_write
  …
```

A hook would show up as `★ HOOKED  0xffffffffc0a12345  <unknown>` with a
note that the address is in the module memory range — same shape as
`check_syscall`.

Test dump: **7 drivers, 259 ops audited, 0 hooked, 0 suspicious**.

**keyboard_notifiers** walks `keyboard_notifier_list`, which is an
`atomic_notifier_head` whose `head` field is a linked list of
`notifier_block`. Each entry's `notifier_call` function pointer is
invoked on every keyboard event — a rogue `notifier_call` is a
ready-made kernel keylogger.

```
# 0 entries in keyboard_notifier_list: 0 ★ HOOKED, 0 SUSPICIOUS
```

A clean Linux desktop usually has 0–2 entries (VT subsystem might
register one). Anything beyond that — especially with `notifier_call`
pointing outside kernel text — is high-confidence malicious.

## check_idt + check_afinfo + check_creds + check_modules (v0.13)

The four-plugin **Tier-5A bundle**. All four reuse the same
`classify_ptr` machinery as `check_syscall` (v0.8) and `tty_check`
(v0.9) — different data sources, identical "is this in kernel text +
does it resolve to a kallsyms function?" classification.

| Plugin | Source | What it checks | Test-dump result |
|---|---|---|---|
| **check_idt** | `idt_table` (256 gate_structs × 16 B) | Each gate's handler points into the kernel image | 256/256 OK |
| **check_afinfo** | `tcp4_seq_ops`, `tcp6_seq_ops`, `udp_seq_ops`, `udp6_seq_ops`, `udplite_seq_ops`, `arp_seq_ops`, `raw_seq_ops`, `unix_seq_ops`, `packet_seq_ops` | Each protocol's `seq_operations` vtable (4 fn ptrs: start/stop/next/show) | 32/32 OK |
| **check_creds** | walks every visible task's `task.real_cred` | Root creds shared by ≥ 2 user-mode tasks (credential-stealer pattern) | 331 unique creds, 0 flagged |
| **check_modules** | `modules` list-walk × `mod_tree` latch-tree walk | Modules in one set but not the other (rootkit unlinked-from-list hide) | 74/74 symmetric |

### Engineering notes worth remembering

**check_idt → wider kernel-image bounds.** Our original
`classify_ptr` used `[_stext, _etext]` (just `.text`). The IDT keeps
pointing at `early_idt_handler_array` for early exception vectors —
that lives in `.init.text`, past `_etext`. The fix in v0.13 was to
prefer `[_text, _end]` bounds (the *full* kernel image), falling
back to `_stext/_etext` if those aren't in kallsyms. All other
`classify_ptr` consumers benefited automatically.

**check_modules → walk one latch half, not both.** `mod_tree` is a
**latch_tree** (kernel/locking/latch.h) — two PARALLEL rb-trees that
share data. Initial implementation walked both halves AND tried both
container_of offsets per rb_node, producing 459 entries (mostly
garbage from the wrong arithmetic) instead of the expected 74.
Walking one half (with the right container_of offset for that half)
gives the clean count.

## ebpf — every loaded eBPF program (v0.14)

eBPF is a modern attack surface that bypasses most traditional rootkit
detectors. A `kprobe`-attached eBPF program can intercept any syscall,
redirect filesystem reads, suppress process visibility — and won't
appear in `lsmod`, `/proc`, `netstat`, or even `bpftool` if the
attacker is careful with cgroup boundaries.

`/sys/findevil/ebpf.txt` walks `prog_idr` (the kernel's xarray of every
`bpf_prog *`) and surfaces every loaded program:

```
   57   CGROUP_DEVICE              167   03b4eaae2f14641a    90909216726   s_firefox_firef
   61   CGROUP_DEVICE              293   c8b47a902f1cc68b   127754485541   sd_devices
   63   CGROUP_SKB                  59   6deef7357e7b4530   127802448536   sd_fw_egress
   ...
```

Columns: `id  type  jited_len  tag  load_time  name  bpf_func`.

**Forensic note in the file**: TRACING / KPROBE / TRACEPOINT /
RAW_TRACEPOINT / LSM programs without an associated user process are
the modern-rootkit pattern. XDP programs on suspicious interfaces drop
traffic. Test dump: 20 programs, all CGROUP_DEVICE / CGROUP_SKB
(systemd's cgroup filters + firefox sandbox) — zero rootkit-likely
types.

## entropy — packed / encrypted code detection (v0.14)

For every user-mode task, samples up to 8 pages of each EXEC VMA, computes
Shannon entropy (bits/byte). Threshold ★ HIGH at ≥ 7.0:

| Range | Typical content |
|---|---|
| 0.0 – 4.0 | Text, shell scripts, structured data |
| 4.5 – 6.5 | Honest x86_64 machine code |
| 6.5 – 7.0 | Compressed text / mixed code+data |
| **7.0 – 7.5** | **Compressed binaries (Go, PyInstaller); flagged** |
| **7.5 – 8.0** | **Encrypted / packed (UPX, custom); high suspicion** |

Per-process file at `/proc/<pid>/entropy.txt` (every EXEC VMA listed
with its entropy); aggregated at `/sys/findevil/entropy.txt` (only
HIGH hits across the whole system). Test dump: 5 hits across 3
processes, all 7.06-7.29 file-backed (Go/PyInstaller territory; not
malicious, flagged for review).

## hidden_modules

First-cut implementation: count kallsyms entries whose address falls in
the module-VA range (`0xffffffffc0000000+`) but **outside** any visible
module's memory layout (`mod.mem[*].base..base+size`). Each orphan is a
hint that a hidden module is loaded and registered with kallsyms but
unlinked from the `modules` list.

A more aggressive future implementation would walk `mod_tree` (the per-
address rb-tree of all loaded modules; rootkits often forget to scrub it)
and diff that against the visible list.

## Per-process malfind file

`/proc/<pid>/malfind.txt` is the same output, scoped to one process:

```
$ memnixfs --dump dump.lime cat "/proc/3096-firefox/malfind.txt"
# pid 3096 (firefox): 1 anonymous-executable region(s)
# (vDSO/signal-restorer pages excluded; ★ = RWX or exec-stack — an
#  injection marker. RX-anon is JIT-or-injected: check 'content'.)
# sev vm_start          vm_end             perms  size      content / reason
#---+-----------------+-----------------+------+---------+----------------
    0x0016e011238000  0x0016e011246000  r-x      57344 B  non-zero [b8 01 00 00 00 c3 ...]
                                                          anonymous executable mapping (RX) — JIT or injected code; inspect
```

Useful when you've already narrowed down a suspect PID from other tools
and want a per-process triage view. (The `[vdso]` page that used to clutter
every process's listing is no longer shown.)

## Robustness

- VMA walker capped at **100 k entries per process** (`vma.cpp`); corrupt
  mm_struct slabs can't blow up the heap.
- `find_malfind` wraps `enumerate_vmas` in `catch(...)`; the aggregated
  walker also wraps each per-pid call. One bad pid → one log line, the
  rest of the report continues.
- psscan's cross-validation step uses a single direct-map physical read
  per candidate — fast even at the hot 600-candidates-/-MB rate.

## ISF symbols & types required

| Symbol | Used for |
|---|---|
| `init_task` | task_struct cross-validation via direct_map (for the visible list) |

| Struct | Fields |
|---|---|
| `task_struct` | `comm`, `pid`, `tgid`, `tasks`, `mm`, `__state` (or `state`) |
| `vm_area_struct` | `vm_start`, `vm_end`, `vm_flags`, `vm_file` (via `vma.cpp`) |
| `module` | `mem[]` for hidden_modules range checks |

## Where this fits in MemProcFS / vol3 parity

| What we expose | vol3 plugin | MPFS module |
|---|---|---|
| `/sys/findevil/malfind.txt` & `/proc/<pid>/malfind.txt` | `linux.malfind` | `m_evil_proc1.c` |
| `/sys/findevil/psscan.txt` | `linux.psscan` | (concept in `m_evil_proc1.c`) |
| `/sys/findevil/hidden_modules.txt` | `linux.hidden_modules` | `m_evil_kernproc1.c` |
| `/sys/findevil/findevil.txt` | — (vol3 has no aggregator) | `m_fc_findevil.c` |
