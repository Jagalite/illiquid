# Foundation Data copy residency discriminator

This standalone macOS experiment investigates how a large `Data(bytes:count:)`
copy can change allocator accounting and immediate process residency in different
directions. It does not change the player or assume which allocator/VM mechanism
explains a particular observation. No native result is claimed by the harness.

## Source-backed motivation

The pinned Swift Foundation source selects a page-copy path for copies of at
least four VM pages when **both** pointers are page-aligned. Its Darwin helper
calls `vm_copy`, falling back to `memmove` on failure. See
[`__DataStorage.move`](https://github.com/swiftlang/swift-foundation/blob/dbacc67779dc0a41ddc9493acbaa332d76c9fb03/Sources/FoundationEssentials/Data/Data.swift#L144-L177)
and [`Platform.copyMemoryPages`](https://github.com/swiftlang/swift-foundation/blob/dbacc67779dc0a41ddc9493acbaa332d76c9fb03/Sources/FoundationEssentials/Platform.swift#L64-L76).

In the pinned XNU source, aligned destination replacement can remove old
destination pmap mappings without eagerly installing the new mappings. ARM64
mapping removal debits residency and relevant footprint ledgers; reusable and
other accounting categories receive different treatment. See
[destination overwrite](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/vm/vm_map.c#L11205-L11280)
and [mapping-removal accounting](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/arm/pmap/pmap.c#L4341-L4395).

These public revisions motivate the controls; they are **not a verified match to
the host's shipping Foundation or kernel binaries**. The probe tests whether
observations depend on alignment, priming, reuse, and read-touching. Merely finding
freed pages in a cache is insufficient to explain an RSS/footprint change, and a
matching effect here would not establish the cause of a separate player result.

## Conditions and controls

Each condition runs in a fresh process, using a manually allocated source whose
entire requested allocation is initialized with nonzero bytes. The logical
payload follows the deterministic pattern `1 + (index % 251)`.

| Axis | Values |
|---|---|
| Payload | 2, 4, 16 MiB |
| Source pointer | Page-aligned; one byte beyond the aligned allocation base |
| Source allocation | `posix_memalign(page size, payload + page size)`, identical size for both pointer alignments |
| Cache protocol | Clean start; clean start followed by one deliberately dirtied and freed payload-size block |
| Copy cohort | Foundation `Data(bytes:count:)`; `malloc` plus a C volatile byte loop; explicit aligned `vm_copy` |
| Paired action | No copy; copy |

The `vm_copy` cohort uses an aligned source and a `posix_memalign` destination.
It has no offset-source condition. Priming matches each cohort's allocation API:
Data constructs a temporary `Data(bytes:count:)` and dirties all bytes through its
unique mutable borrow; the byte-loop cohort uses `malloc(payload)`; the VM-copy
cohort uses `posix_memalign`. A non-inlined helper destroys the Data primer before
the priming-freed checkpoint. Both actions within a cohort execute the same
priming, but cross-cohort priming is intentionally different: a generic malloc
block need not share the Data allocation's zone or allocation bucket.

Address reuse is an observation rather than a prerequisite: a new Data allocation
can choose a different size, zone, address, or alignment. The probe records actual destination
alignment, `malloc_size`, zone name/address, and equality with the primed block's
numeric address. It never reads a freed block. The byte-loop control does not use
`Data(count:)`, whose allocation policy would add another variable.

"Clean" describes a protocol, not a guarantee that all allocator caches or VM
state are empty. Every process performs a small 64-byte Foundation warmup and
`malloc_zone_pressure_relief(NULL, 0)` before allocating its source. The primed
condition then allocates, writes every byte of, measures, and frees one block.
Snapshots while that block is live and after it is freed reveal whether resident
charges actually remained on that process. Pressure-relief return values are
recorded; the harness does not assume that relief releases every cached page.

Release uses six balanced AB/BA pairs for each of 30 conditions: 360 observations.
Debug uses one pair per condition for full content/lifetime coverage: 60 more.
The fixed complete order is saved before any observation. Performance summaries
use release only; no samples are discarded. C volatile helpers use `-O2` in both
Swift configurations, and Swift uses `-Onone` or `-O` respectively.

## Checkpoints and ownership

The fixed checkpoints are source initialization, priming block live, priming
block freed, immediately before copy, immediately after copy, after reading every
destination byte, after reading every source byte, after allocator pressure
relief, after source release, after full destination validation, after destination
release, and after final allocator pressure relief. Unprimed conditions retain
the same named priming checkpoints but do not allocate a priming block.

Each snapshot captures `malloc_zone_statistics(NULL)` live/allocated bytes and
block count plus `TASK_VM_INFO` resident size, physical footprint, internal,
reusable, and compressed bytes. The first post-copy snapshot precedes destination
reads and allocator-zone introspection. Copy timing includes destination
construction/allocation and copying, and excludes all touching, validation, and
snapshots. No sleep is used. All read/write loops are C volatile accesses confined
to the requested allocated bounds.

The Data storage is borrowed with `withUnsafeBytes` throughout the touch,
source-release, and validation checkpoints. After freeing the source, the probe
validates **every destination byte against the known pattern**, then releases the
destination. It never uses the source pointer after release. The no-copy controls
perform the same source touches/releases without creating a destination.

The JSON summary reports each paired effect as:

```
(copy checkpoint - copy before_copy)
  - (no-copy checkpoint - no-copy before_copy)
```

Every median includes its observed minimum and maximum; raw observations retain
all stage counters. The summary also reports priming-live/free changes from the
source-initialized checkpoint, destination alignments/zones, and address reuse.
An immediate RSS/footprint reduction does not alone establish less owned payload
storage. A touch-sensitive effect, an address-reuse effect, or resemblance to the
explicit VM-copy control is evidence to assess, not proof of Foundation's exact
executed implementation. This probe does not trace kernel calls, identify VM
regions, estimate whole-player memory savings, or claim a player speedup.

## Reproduction and evidence

On a native macOS host with the selected Xcode installation:

```sh
DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer \
  python3 Benchmarks/FontCopyResidency/run.py --output /tmp/font-copy-residency
```

The output directory must be new or empty. The runner checks the shared Kyoto
path from the main-branch `AGENTS.md` before compilation. On an isolated host where
that path is absent it explicitly prints the limitation and compiles directly. If
Kyoto exists it stops: this runner does not implement the required
`submit`/`show`/`logs`/`wait` completion protocol and must not bypass that queue.

The workflow uses macOS 26 and Xcode 26.6, with a 15-minute timeout. It needs only
the system SDK, Foundation, Swift, and Clang; there is no FFmpeg or application
build. It saves exact source copies and hashes, compiler versions and hashes,
canonical base64 copies and hashes of the object/both binaries, linked-library listings, selected allocator environment,
OS/SDK/hardware identity, exact commands, complete execution order, every raw
stdout/stderr, all JSON observations, and descriptive summaries. An incomplete
manifest and command logs survive a compilation or process failure. The workflow
uploads those receipts and emits a SHA-256-addressed gzip evidence bundle in logs.

Local input and order checks do not compile or execute the probe:

```sh
python3 Benchmarks/FontCopyResidency/run.py --validate-inputs
```
