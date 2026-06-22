# Crash, log, and journal evidence

MemNixFS exposes conservative crash and log triage under `/sys/crash/` and
`/sys/journal/`.

The important rule: missing memory evidence is not proof that an event did not
happen. If a log file was not resident in page cache, the report says it could
not be recovered. It does not say there was no crash.

## Paths

```
/sys/crash/
    summary.txt       concise source availability + finding counts
    events.txt        matched panic/oops/lockup/OOM/filesystem events
    call_traces.txt   grouped panic/oops/call-trace excerpts from dmesg

/sys/journal/
    index.txt         cached syslog/journald/filesystem-journal candidates
    text_logs.txt     recovered syslog-style text logs, when cached
    journald.txt      best-effort cached systemd-journal evidence

/sys/pagecache/
    recovery.txt      fast per-file gap-confidence catalog from size/page counts
```

Crash events with high confidence are also added to
`/forensic/timeline.txt`. Unavailable sources do not create timeline rows.

## Evidence states

Reports use explicit source states:

| State | Meaning |
|---|---|
| `checked` | The needed source bytes were recovered and scanned. |
| `partial` | Some metadata or bytes were recovered, but missing page-cache pages, unreadable physical pages, sparse zero-fill, or v1 limits prevent a complete claim. |
| `unavailable` | The source could not be recovered from this memory dump. |
| `unverified` | The evidence exists in memory, but needed corroborating metadata is not available. |

Example:

```
/sys/dmesg: checked: dmesg recovered and scanned
/var/log/messages: partial: missing cached pages; sparse zero-filled gaps are synthetic
result: partial: no matching crash pattern found in recovered portions; missing gaps were not checked
```

That means no matching pattern was found only in bytes that were actually
recovered. It does not prove that disk-only logs, missing page-cache ranges, or
unreadable physical pages were clean or even present.

## Filesystem consistency

`/sys/journal/index.txt` includes a small filesystem-consistency section. This
does not replay ext4 JBD2, XFS logs, or btrfs journals.

An inode visible in memory but not verifiable against an on-disk allocation
bitmap is reported as `unverified`, not suspicious. An inode/bitmap mismatch is
only valid when all of these are true:

- inode metadata was recovered,
- the relevant allocation bitmap metadata was recovered,
- the filesystem parser supports that metadata,
- and the mismatch is reproducible.

Full journal replay is deferred until MemNixFS has disk-image support or a
clear cached-journal test case with enough resident metadata.
