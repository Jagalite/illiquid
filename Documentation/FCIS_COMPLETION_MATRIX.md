# Functional-core / imperative-shell completion matrix

This is the current closeout contract for the playback authority migration. The
historical shadow-mode mapping remains available at Git revision `61db384` as
development evidence; it is not the current contract.

## Ownership rules

- **Core** owns deterministic product decisions and logical playback state.
- **Native executor** owns FFmpeg, decoder, queue, clock, renderer, and other
  real-time mechanisms. It reports typed facts and identified outcomes.
- **Player shell** owns playlist policy, persistence execution, runtime lifetime,
  and the explicit composition of core state with telemetry.
- **App shell** owns windows and interaction-only state.
- A native acknowledgement may aggregate tightly coupled work. Its contract must
  state what it proves, preserve identity, represent failure/cancellation, and be
  fault-injectable.

## Commands

| Item | Owner | Current status | Completion evidence |
| --- | --- | --- | --- |
| Load source | Core | Real | Typed command produces an identified native prepare operation |
| Play / pause | Core | Real | Applied-rate acknowledgement carries the originating effect context |
| Seek request | Core | Real | Typed command produces one aggregate seek-pipeline operation |
| Stop | Core | Real | Session cancellation completes after worker quiescence |
| Shutdown | Core | Real | Finalization completes after native teardown and lease release |
| Checkpoint | Core policy / player executor | Real | Store success or failure completes the persistence effect |
| Select audio track | Core | Real | Prepare/commit outcome updates effective selection |
| Select subtitle track | Core | Real | Prepare/commit outcome updates effective selection |
| Set subtitle delay | Core | Real | Applied delay fact must match requested value |
| Add external subtitle | Core policy / native executor | Real | Authorized URL is carried with an identified track-replacement effect |
| Sleep / wake | Core | Real | Lifecycle fact produces an identified pause or wake-preroll transaction |
| Recovery choice | Core | Real | Typed native failure or synchronization fact selects one bounded directive |
| Volume, mute, hardware preference | Player shell | Shell-owned | Device-local preference with explicit native application |
| Playlist next / previous | Player shell | Shell-owned | Core emits EOF advance intent; player chooses collection item |
| Window fullscreen / sidebar / pointer activity | App shell | Shell-owned | No core ownership intended |
| Picture in Picture presentation | App shell | Shell-owned | Platform state is telemetry; transport commands re-enter the core |

## Runtime facts

| Item | Owner | Current status | Completion evidence |
| --- | --- | --- | --- |
| Prepared media catalog | Native executor -> core | Real | Catalog event is accepted for the active authority |
| Logical position | Native clock -> core | Real | Valid active-session clock sample updates the core snapshot |
| Logical duration | Native metadata -> core | Real | Valid active-session duration fact updates the core snapshot |
| Buffer starvation / recovery | Native measurement -> core policy | Real | Core chooses rate transition from reported supply state |
| Clock drift | Native measurement -> core policy | Real | Throttled observation selects wait, correction, re-preroll, or failure policy |
| Midstream format change | Native executor -> core policy | Real | Worker blocks at a generation barrier until the identified reconfiguration completes |
| Preroll readiness | Native executor -> core | Real | Readiness acknowledgement follows required-stream preroll |
| Decoder / presentation failure | Native executor -> core | Real | Typed failure is classified once by the core |
| End of file | Native executor -> core | Real aggregate | Event proves decoder drain and presentation-horizon drain |
| Track catalog metadata | Native executor / player projection | Real | Raw labels are telemetry; effective IDs come from core state |
| Display name and EDR capability | Native/App shell | Telemetry | Never changes core authority |
| Raw queue, frame, and diagnostic counters | Native executor | Telemetry | Bounded diagnostics only; no reducer round trip per frame |

## Effects and acknowledgement contracts

| Item | Owner | Current status | Completion evidence |
| --- | --- | --- | --- |
| Prepare session | Native executor | Real aggregate | One identified result proves input open/probe, decoder configuration, catalog availability, and renderer membership setup |
| Apply rate | Native presentation executor | Real | Renderer/synchronizer accepts the requested rate |
| Seek pipeline | Native executor | Real aggregate | Input interruption, queue/decoder reset, presentation fence, subtitle invalidation, demux seek, and required preroll completed |
| Persist checkpoint | Player executor | Real | Atomic store returns success or typed failure |
| Pipeline drain | Native executor | Real aggregate | Required decoders and presenters reached their final horizon |
| Recovery directive | Native executor | Real | Requested fallback/flush/rebuild completes or fails with the same context |
| Presentation recovery | Native executor | Real aggregate | Audio and video flush acknowledgements precede presenter rebuild completion |
| Decoder recovery | Native executor | Real | Software fallback relaunches decode at the active logical position |
| Format reconfiguration | Native executor | Real aggregate | Queue/presenter reset completes before the blocked worker is released |
| Track replacement | Native executor | Real aggregate | Candidate is prepared and reaches required-stream preroll before commit; failure preserves the old session |
| Subtitle invalidation | Native executor | Real aggregate | Visible overlay and subtitle source revisions are both invalidated |
| Cancel session | Native executor | Real | Workers stop and physical release is observed |
| Finalize shutdown | Native executor | Real | Runtime, surface, subtitles, presentation, borrows, and leases terminate |
| Mirror diagnostic | Diagnostics executor | Allowlisted synchronous | Infallible bounded local append only |

Legacy low-level probe/configure/seek barrier effect cases remain decodable for
old replay fixtures, but the production reducer does not emit them.

## State projection

| Field | Owner | Projection rule |
| --- | --- | --- |
| Lifecycle, phase, desired/actual transport | Core | Always copied from `PlaybackUISnapshot` |
| Position and duration | Core | Native facts enter the reducer before publication |
| Buffering | Core | Derived from synchronization policy state |
| Selected tracks | Core | Effective selection is core-owned; labels come from catalog telemetry |
| Seek, recovery, EOF/drain, failures | Core | Never independently mutated in `PlaybackState`; `coreFailureCode` is projected separately from `shellError` |
| Subtitle selection and delay | Core | Requested/effective values are reducer state |
| Playlist, source origin, resume persistence | Player shell | Explicitly composed with the core projection |
| Video/display/audio-device diagnostics | Runtime telemetry | Explicitly composed and never interpreted as authority |
| Fullscreen, sidebar, pointer/chrome state | App shell | Explicitly composed and never sent to the reducer |

## Completion gate

The migration is complete only when:

1. no core-owned field is independently mutated outside the reducer;
2. every fallible asynchronous effect has a real identified outcome;
3. synchronous success is restricted to the documented allowlist;
4. seek, recovery, EOF, track replacement, and shutdown use the contracts above;
5. delayed, duplicate, stale, failed, and cancelled outcomes pass through the
   production driver tests;
6. static validation prevents core-owned backend bypasses; and
7. required media, sanitizer, soak, package, signature, and manual qualification
   pass after the authority switch.

When those checks pass, the correct completion claim is: the deterministic
functional core is the production behavior authority; the native and player
layers execute identified effects and compose explicitly shell-owned values.
