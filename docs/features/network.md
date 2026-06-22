# Network state

**Status:** v0.37 — TCP, UDP, network interfaces with IPv4 + IPv6 addresses,
ARP/neighbour table, UNIX sockets, routes and netfilter probes, plus
per-process socket cross-reference in `fd_table.txt`.
**Source:** `src/os/linux/netstat.{h,cpp}`, with consumers in
`src/os/linux/fdtable.cpp` (cross-link) and `src/vfs/sys_module.cpp` (VFS).
**Engine cache:** `Engine::socket_index()` builds the TCP+UDP index once
per session via `std::call_once`.
**Cross-ref:** vol3 `linux.sockstat`, `linux.ip.{Link,Addr,Route}`,
`linux.netfilter`; MemProcFS `m_sys_net.c`.

---

## What we expose

```
M:\sys\net\
    tcp           ← every TCP socket (24 on the test dump)
    udp           ← every UDP socket (13)
    interfaces    ← `ip addr` style: lo, ens33 + IPv4 + IPv6
    listening     ← TCP LISTEN + UDP-bound + sock_va
    arp           ← full neigh_hash_table walk — IP/MAC/state/iface
    unix          ← UNIX sockets aggregated from fd_tables
    routes        ← fib_table anchor + path documentation
    netfilter     ← netfilter capability probe + path documentation
    summary.txt   ← cross-protocol single listing

M:\proc\<pid>\fd_table.txt   ← socket fds carry their endpoint info now
```

## Real recovery (Ubuntu test dump)

`/sys/net/tcp` — listeners + established mixed:

```
LISTEN         [::1]:631                          [::]:0           INET6   …  ← CUPS
LISTEN         127.0.0.1:631                      0.0.0.0:0        INET    …  ← CUPS v4
LISTEN         127.0.0.53:53                      0.0.0.0:0        INET    …  ← systemd-resolved
ESTABLISHED    192.168.80.154:38602               142.251.154.119:443  INET ← Google
ESTABLISHED    192.168.80.154:38680               140.82.113.22:443    INET ← GitHub
ESTABLISHED    192.168.80.154:34908               172.217.23.194:443   INET ← Google
…
```

`/sys/net/udp` — DHCP + DNS conversations:

```
ESTABLISHED    192.168.80.154:68                  192.168.80.254:67    ← DHCP
ESTABLISHED    192.168.80.154:53749               192.168.80.2:53      ← DNS
…
```

`/sys/net/interfaces`:

```
  1: lo <UP,LOOPBACK> mtu 65536
       inet  127.0.0.1/8

  2: ens33 <UP,BROADCAST,MULTICAST> mtu 1500
       inet  192.168.80.154/24
```

`/proc/<pid>/fd_table.txt` for systemd shows real socket paths instead
of placeholders:

```
  17  rw-   0x0802         0  socket:NETLINK proto=15
  20  rw-   0x0802         0  socket:UNIX path=/run/systemd/journal/stdout
  21  rw-   0x0802         0  socket:UNIX path=/run/systemd/private
  22  rw-   0x0802         0  socket:UNIX path=/run/systemd/userdb/io.systemd.DynamicUser
 141  rw-   0x0802         0  socket:UNIX abstract=@6694acdd01c63d02/bus/systemd/bus-api-system
 188  rw-   0x0802         0  socket:UNIX path=/run/systemd/notify
```

…and Firefox:

```
  76  rw-   0x0802         0  socket:TCP 192.168.80.154:38602 -> 142.251.154.119:443 ESTABLISHED
```

## Algorithm

```
A) TCP enumeration (tcp_hashinfo symbol)
   1. read inet_hashinfo: ehash + ehash_mask + lhash2 + lhash2_mask
   2. for each ehash bucket (size 8 = inet_ehash_bucket):
        walk hlist_nulls chain at offset 0
        sock_va = nulls_node - offsetof(sock_common, skc_nulls_node)  (= 0x68)
        decode sock_common: skc_daddr/saddr, skc_dport/num, family, state
   3. same for lhash2 buckets (size 16 — listen-bucket lock + nulls_head)

B) UDP enumeration (udp_table symbol)
   1. read udp_table: hash + mask
   2. for each udp_hslot bucket (size 16): walk hlist_nulls chain at offset 0

C) Network interfaces (init_net symbol)
   1. walk init_net.dev_base_head → net_device.dev_list
   2. for each device:
        ifindex, name[16], flags, mtu
        ip_ptr → in_device.ifa_list → in_ifaddr chain
            ifa_local, ifa_prefixlen, ifa_label

D) Per-process fd → socket linkage (in fdtable.cpp)
   1. each fd's file → file.f_inode (already read)
   2. if (i_mode & S_IFMT) == S_IFSOCK:
        socket_va = inode_va - offsetof(socket_alloc, vfs_inode)  (= 0x80)
        sock_va   = read socket_va + offsetof(socket, sk)         (= 0x18)
        look up sock_va in the engine's cached SocketIndex
   3. If found → format as TCP/UDP endpoint + state
      If not (UNIX, NETLINK, PACKET, RAW, ...) → read skc_family + sk_protocol
      directly, then for UNIX: read unix_sock.addr.name → sun_path / abstract
```

The hlist_nulls terminator is the kernel's "the chain ends with a marker
whose low bit is set" convention. Valid sock pointers are 8-byte-aligned,
so `(p & 1) != 0` is the reliable end check.

## Known limitations

1. **Sockets in containers (other net namespaces).** We enumerate the init
   namespace only — any container with its own `mnt_ns + net_ns` is invisible.
   Would need to walk every `task_struct.nsproxy.net_ns` and dedupe.

## ISF symbols & types required

| Symbol | Used for |
|---|---|
| `tcp_hashinfo` | TCP ehash + lhash2 |
| `udp_table` | UDP hash |
| `init_net` | Network interfaces + IPv4 addrs |

| Struct | Fields |
|---|---|
| `sock_common` | skc_daddr/rcv_saddr/dport/num/family/state/v6_daddr/v6_rcv_saddr/nulls_node |
| `sock` | sk_protocol, sk_type |
| `socket` | sk |
| `socket_alloc` | vfs_inode (for inode→socket reverse mapping) |
| `inet_hashinfo` | ehash, ehash_mask, lhash2, lhash2_mask |
| `udp_table` | hash, mask |
| `net` | dev_base_head |
| `net_device` | name, ifindex, flags, mtu, ip_ptr, dev_list |
| `in_device` | ifa_list |
| `in_ifaddr` | ifa_local, ifa_prefixlen, ifa_next |
| `unix_sock` | addr (for fd_table's UNIX-socket path lookup) |
| `unix_address` | name (sockaddr_un with sun_path) |

## Where this fits in MemProcFS / vol3 parity

| What we expose | vol3 plugin | MPFS module |
|---|---|---|
| `/sys/net/tcp`, `udp` | `linux.sockstat` | `m_sys_net.c` |
| `/sys/net/interfaces` | `linux.ip.{Link,Addr}` | `m_sys_net.c` |
| `/proc/<pid>/fd_table.txt` socket rows | `linux.sockstat` (per-PID) + `linux.lsof` | `m_proc_handle.c` |
| `/sys/net/routes` | `linux.ip.Route` | `m_sys_net.c` |
| `/sys/net/netfilter` | `linux.netfilter` | — |
