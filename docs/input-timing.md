# Controller delivery and queued frames

`Console.step/2` drains a completed frame before advancing controller input.
If no frame is queued, it flushes controllers before waiting, preserving the
blocking-input handshake. This applies to both pipe flushes and direct pad
batches.

Previously every call flushed first, including calls returning a frame that
had already completed. With a backlog this advanced the input stream while
the caller was still processing older observations. The regression test in
`test/melee/console_test.exs` queues two completed frames and verifies that
draining them sends neither pipe flushes nor direct batches; requesting the
next frame sends one of each and waits for its response.

This does not make old observations actionable retroactively. Applications
requiring exact causal timing should compare their sent commands against
recorded game inputs and reject incorrectly timed episodes. Polling retries,
game-start neutral input, and rollback flushes are unchanged by the queued-frame fix.

## Retrying a timed-out step

`Console.step(console, timeout, flush: false)` waits for an outstanding frame
without another controller commitment. Use this when a polling step returned
`nil` and there is no new decision. The default `flush: true` preserves the
existing API. A caller must distinguish waiting from intentionally sending new
input, including pause/menu recovery; do not blindly suppress all future input.

Exphil's internal `MeleePort` retry loop previously flushed again on every nil
result. A 1 ms polling stress matrix failed all four timing checks, despite
four blocking and four 100 ms controls passing. That loop now uses wait-only
retries. External polling callers must make the same distinction explicitly.
New deterministic tests cover repeated waits, late frames, and game restarts.

## Validation (2026-09-13)

Exphil's ep57 reaction-2 closed-loop control passed six runs with the patched
console: all chain 14, no prefix divergence, and every tested command recorded
at the expected latency. Six more source-patched reaction-3 controls also pass
with chain 14, no divergence/errors, and the expected latency. The unit suite
passes: 119 doctests, 3 properties, 565 tests; 71 live-Dolphin tests excluded.
The unpatched console also passed a separate six-run
batch, despite earlier intermittent failures. These small batches therefore
do not prove that queued-frame flushing explains all cross-run latency
variation. Keep the input-timing gate enabled.

Evaluation artifacts and continuing diagnostics are tracked in the sibling
Exphil repository, `docs/planning/MULTISHINE_PIPELINE_PROOF.md` and
`eval_runs/0913_policy_control/`.
