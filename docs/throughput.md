# Frame throughput: where the milliseconds go

Profiled 2026-08-17 on `nixos_slanka` (32 cores), ExiAI headless,
`gfx_backend: "Null"`, blocking pipes, `Melee.Transport.EnetBeam`,
Fox vs Falco idle on FD. Probe scripts: `tmp/profile_frames.exs`,
`tmp/profile_pipeline.exs`, `tmp/profile_arrival.exs`,
`tmp/profile_pool.exs` (session-local; the numbers and method live
here).

## The headline numbers

| Measurement | Result |
| --- | --- |
| Blocking `Console.step`, wall time | mean ~1.9ms, **p50 = 2119us**, p90 = 2145us — a tight floor, not jitter (~527fps) |
| BEAM CPU share during that loop | **0.03%** of scheduler wall time |
| `Slippstream.decode` (JSON + base64, live payloads) | 2.2us/message |
| Spectator traffic | exactly **1 packet per frame**, ~503B |
| `Session.step` vs `Console.step` | no measurable difference (the extra GenServer hop is noise) |
| Non-blocking natural pace | **~1078fps** (0.93ms/frame) right after GO; ~570fps deeper into idle gameplay |
| Input pre-buffering (1-2 extra FLUSHes primed) | **no effect** — p50 pinned at 2119us at every depth |
| Packet inter-arrival, non-blocking | bimodal: **~1065us and ~2119us and nothing else** (2119 = 2 x 1060 exactly) |
| Concurrent blocking sessions | 1 -> 535fps; 2 -> 883 total; 4 -> **1830 total** (~455fps each, ~86% efficiency) |

## What this rules out

The Elixir side is exonerated end to end. During the blocking loop
the BEAM is idle 99.97% of the time; JSON+base64 decode of the one
per-frame packet costs 2.2us against a 2100us frame; the
`Session.step` wrapper hop, the controller GenServer + fifo write
path (p50 ~6us, measured earlier in exphil's bridge bench), and the
EnetBeam ack traffic are all noise. **No amount of BEAM-side protocol
work — batching, serialization, transport swaps — can move the
frame rate meaningfully.**

It also rules out the input path: priming extra FLUSHes so Dolphin
always has the next frame's inputs buffered (a 1-frame-delay
pipeline, which exphil's ActionQueue could have absorbed for free)
changed nothing. Dolphin is not waiting on us.

## What the evidence says is happening

Every inter-arrival in non-blocking mode is one or two periods of a
**~1.06ms clock**, and the blocking round trip is always exactly two.
That is the signature of the Slippi spectator server's service loop
(a thread alternating `enet_host_service(..., ~1ms)` with
queue-draining): a frame finishing emulation waits in Dolphin's own
send queue for the next service-loop wakeup, and the blocking
request/response phase relationship lands the reply consistently two
wakeups after our flush. The frame time we observe is Dolphin-side
scheduling latency, not emulation cost (emulation is well under 1ms —
the natural pace right after GO shows ~0.93ms/frame including
streaming).

## The spectator patch (landed 2026-08-17, same day)

The Dolphin-side fix from item 2 below is DONE. vladfi1's
slippi-Ishiiruka fork at the `exi-ai-0.2.0` release commit, patched on
the local branch `spectator-flush-on-frame`
(`~/git/slippi-Ishiiruka`, commit `080a8c6c7`): the spectator thread
now waits on a condition variable that `write()` notifies and treats
`enet_host_service` as a non-blocking flush, so a frame's events go
out the moment the game thread produces them instead of on the next
~1ms service tick. The 1ms `wait_for` fallback preserves the old
cadence for enet housekeeping, so the worst case IS the old behavior.

Measured against the same benchmarks (patched binary installed at
`~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless`):

| | stock ExiAI | patched |
| --- | --- | --- |
| Blocking step p50 | 2119us | **1755us** |
| Blocking step p99 | 3216us | **1856us** |
| Solo fps | ~535 | **~569** |
| 4-concurrent aggregate | 1830 | **2117** (~530 each — the per-session penalty nearly vanished) |

The telling detail: the patched p50 (1755us) equals the OLD run's
mean natural inter-arrival during active gameplay (1760us) — the
bimodal 1065/2119 pattern was service-tick quantization of an
underlying ~1.76ms emulation time, and it is gone. **The blocking
step is now emulation-bound**: further per-instance gains mean making
Melee emulate faster (e.g. Fizzi's fast-forward gecko that slippi-ai
credits for its RL speedup — it skips rendering-only work), not
transport work. Correctness on the patched build: `dolphin_replay`
(byte-identical recording), `dolphin_rules`, `dolphin_teams`,
`dolphin_tech` (frame-perfect multishine) all pass.

Rebuild recipe: `nix-shell` (the branch carries a `shell.nix`), then
`cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DLINUX_LOCAL_DEV=true
-DDISABLE_WX=true -DENABLE_HEADLESS=true -DENABLE_ALSA=false
-DENABLE_PULSEAUDIO=false -DENABLE_EVDEV=false` and
`make dolphin-nogui`, then copy `Data/Sys` beside the binary.

## EXI inputs + fast-forward (landed 2026-08-18)

The "next lever" predicted below is DONE:
`Melee.Dolphin.launch(exi_inputs: true, ffw: true)` (passed through by
`Session`/`Probe`) enables the two gecko codes the ExiAI build ships —
`$Optional: Allow Bot Input Overrides` (the game pulls pad state over
the Slippi EXI device, `CMD_OVERWRITE_INPUTS`, instead of Serial
Interface polling) and `$Optional: FFW VS Mode` (fast-forward, which
that decoupling makes possible). Semantics mirror Python libmelee:
`ffw` without `exi_inputs` errors, and `exi_inputs` on a non-ExiAI
binary is refused via the `--version` probe.

Measured on the flush-patched build:

| | pipes (SI) | exi + ffw |
| --- | --- | --- |
| Blocking step p50 | 1755us | **233us** (p99 372us) |
| Solo fps | ~569 | **~4272** |
| 4-concurrent aggregate | 2117 | **~11800** (HIGH per-session variance: 552-4529 — at these speeds sessions are CPU-bound and contend) |

Correctness: the multishine suite now runs TWICE (`--only dolphin_tech`
covers both; `--only dolphin_ffw` the new path alone) — identical
74 shines / 73 jumpsquats over 600 frames on both input routes, so the
EXI path is frame-accurate, not merely fast.

Caveats to know:

- **Analog triggers are dropped on the EXI input path** (exphil
  GOTCHAS #66): digital L/R work, light shield does not.
- FFW applies to VS gameplay; menus run at the flush-patched pace
  (~1ms/frame), so per-episode menu overhead is unchanged.
- Under concurrency the fair-share scheduling is rough (one of four
  sessions sank to 552fps); a training pool should pin or shard
  instances if per-env pacing matters.

## Consequences for the roadmap

1. **Scale OUT, not up, for training throughput today.** Sessions
   stack near-linearly (~455fps each at 4 concurrent on 32 cores,
   ~86% efficiency); the pool is the cheap 5-10x. Aggregate fps is
   what a training loop cares about; per-env latency only matters
   for real-time evaluation.
2. **Per-instance latency is a Dolphin-side fix.** The two candidate
   attacks, in order: patch the ExiAI fork's spectator service loop
   (flush the frame packet on the frame boundary instead of the next
   ~1ms wakeup — plausibly recovers to ~1.1ms/frame, ~900fps), or
   bypass the spectator socket entirely via the EXI direct channel
   (roadmap item; larger scope, larger ceiling).
3. **Do not spend effort on BEAM-side protocol changes** — the
   profiling above is the receipt.

## Method notes (for re-running)

- Wall-vs-CPU split: `:erlang.system_flag(:scheduler_wall_time,
  true)` around the timed loop; busy fraction over all schedulers.
- Packet cadence: `:erlang.trace(console, true, [:receive,
  :monotonic_timestamp])` and diff the `:enet_packet` timestamps.
- Natural pace: `blocking_input: false`, drain via polling steps,
  count frame-id advance over wall clock. Beware the pre-GO
  countdown: frames -123..0 emulate faster than live gameplay, so
  measure both windows before comparing.
- `:eprof` is unavailable in this OTP install; it was not needed —
  the 0.03% busy figure made a function-level breakdown moot.
