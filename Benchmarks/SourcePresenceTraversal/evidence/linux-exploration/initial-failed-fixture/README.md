# Initial failed fixture attempt

This attempt stopped in the pinned baseline's debug test run, before any
performance measurements. The two new traversal tests recorded four failed
expectations because directories named `Directory.mp4` and `Empty.mkv` were not
reliable ordinary-directory fixtures under Foundation's package classification.
The cursor already skips packages; production behavior was preserved.

The corrected fixtures use `Directory mp4 collection` and `Empty mkv collection`.
The source receipts confirm that every production file in both implementations
is byte-identical across the failed and corrected attempts. The harness also
received two preparation/iteration-scope refinements before the retry; the
retained `fixture-and-harness-corrections.patch.gz` preserves the exact unified
diff of those changes and the fixture correction. Compression retains legitimate
blank context lines without introducing trailing whitespace into tracked text.

`completion.json`, `commands.jsonl`, `sources.json`, and `manifest.json` retain the
original failure and its inputs. `baseline-debug-tests.log.gz` is the complete
failed test log. The original test and harness sources are retained as separate
compressed files, with their hashes in `receipt.json`. No measured observations
were discarded from this attempt: it produced none.
