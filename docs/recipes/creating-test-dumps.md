# Creating test dumps

You can build a fresh Linux memory dump for testing MemNixFS in a few
minutes. This page documents several approaches, ordered by ease.

## Option 1 - AVML on a live Linux box (easiest)

Works on any Linux system with `/proc/kcore` access, which usually means
root. Produces a `.lime.compressed` file.

```bash
# On the target Linux system:
wget https://github.com/microsoft/avml/releases/latest/download/avml
chmod +x avml
sudo ./avml --compress /path/to/output.lime.compressed
```

About 30 seconds for 8 GB of RAM. The resulting file is usually 10-25% of
physical RAM size because AVML uses Snappy compression.

### Caveat: gaps

AVML reads through `/proc/kcore` or `/dev/crash`. Both expose only pages the
kernel considers addressable, so non-resident or filtered pages are skipped.
This can leave gaps inside the kallsyms region. MemNixFS is gap-tolerant for
`kallsyms_names`, but gaps inside `kallsyms_offsets` can prevent address
resolution. If you need a guaranteed gap-free dump, use the QEMU `pmemsave`
option.

## Option 2 — LiME on a live Linux system

LiME is a Linux kernel module used to capture physical memory from a live Linux machine. Use this when you want a classic uncompressed `.lime` dump instead of AVML’s `.lime.compressed` Snappy-framed format.

### 1. Install dependencies

On the target Linux system:

```bash
sudo apt update
sudo apt install -y build-essential git linux-headers-$(uname -r)
```

If the headers package cannot be found, your running kernel may not match the repository headers. Upgrade, reboot, and try again:

```bash
sudo apt full-upgrade -y
sudo reboot
```

After reboot:

```bash
uname -r
sudo apt install -y build-essential git linux-headers-$(uname -r)
```

Verify the headers exist:

```bash
ls -ld /lib/modules/$(uname -r)/build
```

### 2. Build LiME

```bash
cd ~/Desktop
git clone https://github.com/504ensicsLabs/LiME.git
cd LiME/src
make
```

Confirm the kernel module was built:

```bash
ls -lh lime-*.ko
```

### 3. Capture memory

Choose an output path with enough free space. The dump is usually close to the size of RAM.

Example:

```bash
mkdir -p ~/Desktop/memdump
sudo insmod ./lime-*.ko path=/home/kali/Desktop/memdump/output.lime format=lime
```

If quoted parameters fail, use the unquoted form above.

Check progress or errors:

```bash
sudo dmesg | tail -50
```

Verify the dump was created:

```bash
ls -lh /home/kali/Desktop/memdump/output.lime
sha256sum /home/kali/Desktop/memdump/output.lime | tee /home/kali/Desktop/memdump/output.lime.sha256
```

### 4. Unload LiME

After acquisition finishes, unload the module:

```bash
sudo rmmod lime
```

Confirm it is unloaded:

```bash
lsmod | grep lime
```

No output means it is unloaded.

If another `insmod` attempt says `File exists`, LiME is already loaded. Check and unload it before starting another capture:

```bash
lsmod | grep lime
sudo dmesg | tail -50
sudo rmmod lime
```

### 5. Optional compression

LiME output is usually close to RAM size. Compress it after acquisition if needed:

```bash
xz -T0 -9 /home/kali/Desktop/memdump/output.lime
```

This creates:

```text
output.lime.xz
```

If you compress with generic `xz`, decompress it before passing it to MemNixFS unless the reader explicitly supports `.xz`.

Do not confuse this with AVML’s `.lime.compressed` format. AVML uses a different Snappy-framed wrapper.


### 6. Truncated dump warning

MemNixFS validates LiME segment sizes when opening the file. If the headers describe more memory than the file actually contains, the dump was truncated and must be recaptured.

Example error:

```text
LiME: truncated segment 3 at offset 0xbff66c60:
PA range 0x100000000-0xdb6ffffff needs 0xcb7000000 bytes,
but file has only ...
```

A healthy uncompressed LiME dump is usually close to the total captured physical memory reported by the LiME headers. For example, a 56 GB physical memory map cannot fit into a 3.2 GB uncompressed `.lime` file unless the acquisition was cut short.


## Option 3 - QEMU `pmemsave` (gap-free, about 5 min)

Boot a small Linux VM under QEMU, then dump its entire physical memory from
the hypervisor side. The QEMU monitor sees the actual VM RAM the way a real
hypervisor does: no `/proc/kcore` filtering and no gaps. This is the dump
format MemNixFS gets its best coverage on.

### Recipe (Linux host, WSL host, or anywhere QEMU runs)

```bash
# Get a small Linux ISO (Alpine virt = about 60 MB, fastest boot)
cd /tmp/memnix-vm
curl -fLO https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-virt-3.21.0-x86_64.iso

# Boot QEMU. Send pmemsave then quit after 30 seconds of boot.
# This runs entirely in the foreground for about 90 seconds total.
(sleep 30
 echo "pmemsave 0 0x40000000 /tmp/memnix-vm/dump.raw"
 sleep 60
 echo "quit") | \
  qemu-system-x86_64 \
    -enable-kvm \
    -m 1G \
    -smp 1 \
    -cdrom alpine-virt-3.21.0-x86_64.iso \
    -display none \
    -monitor stdio \
    -serial null

ls -lh /tmp/memnix-vm/dump.raw   # 1.0 GB

# If you're on Windows + WSL, copy it where Windows can see it:
cp /tmp/memnix-vm/dump.raw "/mnt/c/Users/<you>/Desktop/wsl_kvm.raw"
```

Then point MemNixFS at it:

```powershell
memnixfs --dump C:\Users\<you>\Desktop\wsl_kvm.raw --no-http-cache list
# kallsyms: 135809 symbols (relative_base = 0xffffffff9b000000)
# Total: 63 processes
```

### Why this is the recommended test dump

- Every byte of physical RAM is captured.
- `kallsyms_offsets` and `kallsyms_relative_base` are fully present, so
  address resolution works.
- BTF is fully present, so all types resolve.
- Reproducible: run the script again and get the same kernel build because
  the Alpine ISO version is pinned.

### Variants

**Bigger VM:** change `-m 1G` to `-m 2G` and `pmemsave 0 0x80000000`.

**Ubuntu instead of Alpine:** use any cloud image, such as
`-cdrom ubuntu-cloud.img`.

**Without KVM:** drop `-enable-kvm`; boot takes about 90 seconds instead of
about 15 seconds.

## Option 4 - `kdump` (proper crash dump, advanced)

Real `kdump` requires:

- A pre-reserved crash kernel at boot, such as kernel parameter
  `crashkernel=...`.
- `kexec-tools` installed.
- A panic to trigger the dump, or `echo c > /proc/sysrq-trigger`.

Produces a `vmcore` ELF file in `/var/crash/<timestamp>/`.

MemNixFS reads kdump/vmcore-style ELF64 dumps. If you need to normalize or
filter the crash dump first, use `makedumpfile`:

```bash
sudo makedumpfile -E -F -x vmlinux /var/crash/<timestamp>/vmcore vmcore.elf
```

Then point MemNixFS at the resulting `vmcore` or converted ELF file.

## Option 5 - Hypervisor exports

Most hypervisors can dump VM RAM directly:

| Hypervisor | Command |
|---|---|
| **QEMU/KVM (libvirt)** | `virsh qemu-monitor-command <vm> --hmp 'pmemsave 0 <size> <path>'` |
| **VirtualBox** | `VBoxManage debugvm <vm> dumpvmcore --filename <path>` (ELF format) |
| **VMware Workstation** | Suspend the VM; the `.vmem` file is the dump |
| **VMware ESXi** | `vim-cmd vmsvc/snapshot.create` then extract `.vmem` |
| **Hyper-V** | Create a checkpoint, then read the `.vmrs` file (more complex) |

VirtualBox's `.elf` output, VMware `.vmem`, and raw hypervisor memory files
work directly when their layout is raw physical memory or supported ELF64
kdump/vmcore.

## Validating your dump

Quick smoke test once you have a dump:

```powershell
# Should report a Linux kernel release and a process count.
memnixfs --dump <file> list

# Should produce a kernel VA for init_task.
memnixfs --dump <file> kallsyms init_task
# 0xffffffff9c810940 D init_task

# Should mount cleanly on Windows when built with WinFsp.
memnixfs --dump <file> mount M:
type M:\sys\banner.txt
```

If any of these fail with parser errors, run with `-v` and check the log. The
most common cause is an unrecognized format header. Make sure the dump's
first bytes are AVML's magic (`ELF...AVML`), LiME's magic (`EMiL`), an ELF64
kdump/vmcore header, or a raw image you intend to treat as raw memory.

## File sizes (rough)

| Source | 1 GB RAM | 4 GB RAM | 16 GB RAM |
|---|---|---|---|
| AVML compressed | ~150-250 MB | ~600 MB-1 GB | ~3 GB |
| LiME | ~1 GB | ~4 GB | ~16 GB |
| QEMU `pmemsave` (raw) | 1 GB exactly | 4 GB | 16 GB |
| kdump (compressed) | varies, ~10-30% of RAM | same | same |

For developing MemNixFS, a 1 GB Alpine QEMU dump is the sweet spot: small
enough to iterate fast, big enough to exercise most code paths.
.
