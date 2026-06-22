# ISF JSON format

MemNixFS reads and writes the **Volatility-3 ISF** (Intermediate Symbol
File) format. This page documents the subset of the format we use.

## Overview

An ISF is a single JSON document describing kernel-level types and
symbols for one specific kernel build. It's a portable substitute for
the kernel's vmlinux + DWARF debuginfo.

Typical filename: `<release>.json.xz` (xz-compressed). Uncompressed:
`<release>.json`. Both are accepted by `IsfSymbols::load()`.

## Top-level structure

```jsonc
{
  "metadata": {
    "linux": {
      "symbols": [ { "kind": "btf", "name": "vmlinux-6.14.0-36-generic", "hash_type": "none", "hash_value": "" } ],
      "types":   [ { "kind": "btf", "name": "vmlinux-6.14.0-36-generic", "hash_type": "none", "hash_value": "" } ]
    },
    "producer": { "name": "lmpfs-btf-to-isf", "version": "0.1" },
    "format": "6.2.0"
  },
  "base_types": { … },
  "user_types": { … },
  "enums":      { … },
  "symbols":    { … }
}
```

## `metadata.linux.symbols[0].name`

Carries the kernel release (`vmlinux-<release>`). This is what
MemNixFS's auto-discover uses to match an ISF to a dump:

```cpp
// src/symbols/symbol_resolver.cpp
std::string isf_release(const fs::path& p) {
    auto isf = IsfSymbols::load(p);
    return isf->kernel_release();   // strips "vmlinux-" prefix
}
```

## `base_types`

Primitive types — what C calls "fundamental types". Keyed by name:

```jsonc
"base_types": {
  "char":         { "size": 1, "signed": true,  "kind": "char",  "endian": "little" },
  "unsigned int": { "size": 4, "signed": false, "kind": "int",   "endian": "little" },
  "long unsigned int": { "size": 8, "signed": false, "kind": "int", "endian": "little" },
  "void":         { "size": 0, "signed": false, "kind": "void",  "endian": "little" }
}
```

| Field | Values |
|---|---|
| `size` | Bytes |
| `signed` | True/false |
| `kind` | `"int"`, `"char"`, `"bool"`, `"float"`, `"void"` |
| `endian` | `"little"` or `"big"` |

## `user_types`

Composite types (structs and unions). Keyed by name:

```jsonc
"user_types": {
  "task_struct": {
    "kind": "struct",
    "size": 13952,
    "fields": {
      "state":     { "offset": 0,       "type": { "kind": "base", "name": "long" } },
      "thread_info": { "offset": 16,    "type": { "kind": "struct", "name": "thread_info" } },
      "pid":       { "offset": 2768,    "type": { "kind": "base", "name": "int" } },
      "tgid":      { "offset": 2772,    "type": { "kind": "base", "name": "int" } },
      "tasks":     { "offset": 2560,    "type": { "kind": "struct", "name": "list_head" } },
      "comm":      { "offset": 3312,    "type": { "kind": "array", "count": 16,
                                                   "subtype": { "kind": "base", "name": "char" } } },
      "mm":        { "offset": 2880,    "type": { "kind": "pointer",
                                                   "subtype": { "kind": "struct", "name": "mm_struct" } } },
      …
    }
  }
}
```

| Field | Notes |
|---|---|
| `kind` | `"struct"` or `"union"` |
| `size` | Total size in bytes (for layout calculations) |
| `fields` | Map of name → `{ offset, type }` |

### Field `type` shapes

```jsonc
// Primitive
{ "kind": "base", "name": "int" }

// Pointer to another type
{ "kind": "pointer", "subtype": { "kind": "struct", "name": "task_struct" } }

// Fixed-size array
{ "kind": "array", "count": 16, "subtype": { "kind": "base", "name": "char" } }

// Named struct / union / enum reference
{ "kind": "struct", "name": "mm_struct" }
{ "kind": "union",  "name": "thread_union" }
{ "kind": "enum",   "name": "pid_type" }

// Bitfield (used in struct fields when the C source has e.g. `unsigned int flags:3;`)
{
  "kind": "bitfield",
  "bit_position": 0,
  "bit_length": 3,
  "type": { "kind": "base", "name": "unsigned int" }
}

// Function pointer (we just emit "function" — the actual signature is rare to need)
{ "kind": "function" }
```

### Anonymous union flattening

`IsfSymbols::load()` automatically inlines anonymous-union fields into
their parent. Example:

```c
struct vm_area_struct {
    unsigned long vm_start;
    unsigned long vm_end;
    union {
        struct {
            struct rb_node vm_rb;
            unsigned long rb_subtree_gap;
        };
        struct anon_vma *anon_vma;
    };
    …
};
```

The ISF says `vm_area_struct` has a `__unnamed_0` field of union kind.
Our loader flattens it: `vm_rb`, `rb_subtree_gap`, and `anon_vma` all
get hoisted into `vm_area_struct.fields` at the correct offsets, so
`isf.field_offset("vm_area_struct", "vm_rb")` works.

This was a recurring source of bugs before we added flattening.

## `enums`

```jsonc
"enums": {
  "pid_type": {
    "size": 4,
    "base": "int",
    "constants": {
      "PIDTYPE_PID":   0,
      "PIDTYPE_TGID":  1,
      "PIDTYPE_PGID":  2,
      "PIDTYPE_SID":   3,
      "PIDTYPE_MAX":   4
    }
  }
}
```

We rarely use enums in MemNixFS — most code paths read raw integer
values and compare directly. But ISF consumers do need them, so we
emit faithfully.

## `symbols`

The big one. Keyed by symbol name:

```jsonc
"symbols": {
  "init_task":      { "address": 18446744071576907072 },
  "linux_banner":   { "address": 18446744071575521824 },
  "init_top_pgt":   { "address": 18446744071576338432 },
  "modules":        { "address": 18446744071577265024 },
  …
}
```

`address` is a u64 (decimal in the JSON — JSON has no native u64 hex
literal). For BTF-derived ISFs we populate this from kallsyms; for
DWARF-derived ISFs (`dwarf2json` output) it comes from the DWARF
`.debug_info`.

For non-BTF ISFs, symbols can also carry `"type"` info:

```jsonc
"init_task": { "address": 18446744071576907072, "type": { "kind": "struct", "name": "task_struct" } }
```

We don't currently emit this in BTF→ISF output (the address alone is
sufficient for our engine).

## Sizes (real-world)

| Kernel | Types | Symbols | Uncompressed | xz |
|---|---|---|---|---|
| Ubuntu 6.14.0-36-generic (BTF+kallsyms) | 11,253 | 190,860 | 18 MB | 7 MB |
| Alpine 6.12.1-3-virt (BTF+kallsyms) | 7,400 | 122,487 | 12 MB | 5 MB |
| Ubuntu 6.14.0-36-generic (dwarf2json) | 14,500 | 200k+ | 25 MB | 9 MB |

Our BTF-derived ISFs are slightly smaller because BTF omits some
details DWARF carries (source locations, inline function info), but
all the field offsets and type sizes are identical.

## Producer field

The ISF's `metadata.producer.name` lets consumers know what generated it:

| Producer | Source |
|---|---|
| `dwarf2json` | Standard DWARF-based generation |
| `lmpfs-btf-to-isf` | MemNixFS's BTF parser |
| `vol3-symbols-builder` | Community mirror builder |

This is informational. The engine doesn't treat them differently.

## Format version

`metadata.format = "6.2.0"` — Volatility-3's ISF format version we
target. Vol3 currently accepts this and is forward-compatible. If a
future vol3 bumps the format, we'll update `btf_to_isf.cpp` to match.

## Reference

- Volatility 3 docs: https://volatility3.readthedocs.io/en/latest/symbol-tables.html
- `dwarf2json`: https://github.com/volatilityfoundation/dwarf2json
- Our loader: `src/symbols/isf_symbols.cpp`
- Our emitter: `src/symbols/btf_to_isf.cpp`
