# Playback core shadow mapping (historical)

This document is restored from the Stage 2 shadow migration as historical
evidence. It describes the system at that stage, not the current production
contract. See [FCIS_COMPLETION_MATRIX.md](FCIS_COMPLETION_MATRIX.md) for the
current closeout contract.

Status at capture: Stage 2 observation only. The existing `PlaybackCoordinator`,
selected backend, and native/legacy runtime remained the sole production
authorities. Every effect emitted by the shadow core was recorded and discarded.

## Modeled command flow

| Existing coordinator entry | Shadow event | Current scope at capture |
| --- | --- | --- |
| accepted `playItem` load | `.command(.load)` | Redacted source identity; autoplay intent |
| `play` | `.command(.play)` | Excludes the reload path, which maps as load |
| `pause` | `.command(.pause)` | Requested transport only |
| relative seek | `.command(.seek(..., .relative))` | Microsecond rational input |
| exact seek | `.command(.seek(..., .exact))` | Microsecond rational input |
| preview seek | `.command(.seek(..., .preview))` | Microsecond rational input |
| `stop` | `.command(.stop)` | Observed optimistic-stop behavior |
| `shutdown` | `.command(.shutdown)` | Observed coarse backend shutdown |

Absolute local paths were not stored. Local identities used only
`local:<lastPathComponent>`; remote identities used
`remote:<host>/<lastPathComponent>`.

## Modeled backend results

| Existing backend event | Shadow completion |
| --- | --- |
| `.loaded` | Latest predicted open succeeds |
| `.pauseChanged(false)` | Latest predicted nonzero-rate request succeeds |
| `.pauseChanged(true)` | Latest predicted zero-rate request succeeds |
| `.stopped` | Latest predicted session cancellation succeeds |
| `.shutdownCompleted` | Latest predicted runtime finalization succeeds when present |
| `.failed` | Latest pending non-cleanup effect receives a typed fatal failure |

Events rejected by the production `PlayerEventGate` were journaled as
`rejectedByProductionGate` and were not delivered to the shadow reducer.

## Observed-only facts

The following events were deliberately journaled without inventing Stage 1
reducer semantics:

- started and first-frame submission/presentation;
- position, duration, buffering, tracks, decoder, video, and display changes;
- volume, mute, speed, output devices, chapters, and delay changes;
- video adjustments and Picture in Picture state;
- EOF, diagnostics, and asynchronous facts without a matching predicted effect.

The migration required these to become typed core events in their owning
authority stages. Treating them as generic effect success would have hidden the
distinctions the refactor was intended to establish.

## Baseline semantic differences exposed by shadow mode

1. Production `playItem` called backend load and play immediately. The shadow
   model did not become playing until open and an effective-rate acknowledgment
   were separately observed.
2. Production `.loaded` meant backend construction/probe completed, not preroll
   or visible presentation readiness.
3. Production stop cleared the event gate and marked stopped optimistically, so
   a later scoped `.stopped` event could be rejected. The shadow core therefore
   remained in stopping until an accepted cancellation fact existed.
4. Production shutdown could report completion after the native timeout. The
   shadow core did not call a runtime quiescent merely because an unmapped
   shutdown callback arrived.
5. Position and A/V metrics were submission-level facts. Shadow mode did not
   reinterpret them as displayed/audible time.
6. EOF was observed only until decoder, converter, submission, and presenter
   drain events existed.
7. Backend callbacks lacked the operation/effect identity predicted by the
   core; Stage 2 matched the latest compatible predicted effect strictly for
   comparison, never for authority.

## Journal policy

The in-memory journal was bounded to 512 entries. It contained redacted labels,
event disposition, the predicted snapshot, invariant results, and the number of
discarded effects. It performed no I/O and could not call a backend or native
executor.
