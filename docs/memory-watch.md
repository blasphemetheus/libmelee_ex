# Memory watch: live RAM reads from a running session

`Melee.MemoryWatcher` + `Melee.MemoryMap` turn Dolphin's built-in
MemoryWatcher facility into named, typed, subscribable reads of
Melee's RAM while a session runs. The Slippi stream carries a fixed
schema someone else chose; RAM has everything the game knows. This is
the escape hatch — "the stream doesn't carry X" becomes a config
line, not a wall.

Verified working on the mainline-beta netplay build (2026-08-22 spike,
1,165 datagrams/20s). Read-only; write-side control stays with the
Improoover savestate route.

## The contract, end to end

1. **Start the watcher BEFORE Dolphin** with the same `:home`.
   `start_link` writes `<home>/MemoryWatcher/Locations.txt` and binds
   a Unix datagram socket at `<home>/MemoryWatcher/MemoryWatcher`.
   Dolphin reads the file **once at core start** and `sendto`s the
   socket path unconditionally — a file written after boot is never
   read, and missed datagrams are silently dropped. The
   `:memory_watch` option on `Melee.Dolphin.launch/1` handles the
   ordering for you (watcher started between `prepare_home` and
   spawn; pid at `dolphin.memory_watcher`; stopped in `Dolphin.stop`).
2. Dolphin polls every watched line 600/s and sends a datagram **on
   change only**.
3. Datagrams only flow while **game frames advance** — a core with no
   console pacing it sends nothing. Watch traffic doubles as a free
   "is the game actually running" liveness signal
   (`Melee.MemoryMap.canary/0` watches the always-ticking RNG seed).

```elixir
{:ok, dolphin} =
  Melee.Dolphin.launch(
    path: ..., iso_path: ...,
    memory_card: true,                      # mainline: required (SlotA=255 → pre-video hang)
    memory_watch: Melee.MemoryMap.menu_with_canary()
  )

w = dolphin.memory_watcher
Melee.MemoryWatcher.get(w, :menu_state)          #=> {:ok, 0x02020200}
Melee.MemoryWatcher.get_f32(w, :css_p1_cursor_x) #=> {:ok, -23.04}
Melee.MemoryWatcher.subscribe(w, :menu_state)    # {:memory_watch, :menu_state, value}
Melee.MemoryMap.scene_name(0x02020200)           #=> :character_select
```

## Datagram grammar (the data definition)

The mainline build's format differs from Ishiiruka's classic docs in
one byte that cost an afternoon (2026-08-22 — the parser silently
rejected every real message). Pinned by the input-class battery in
`test/melee/memory_watcher_test.exs`:

```
Datagram  = EmptyStep | Composite
EmptyStep = <<0>>                         ; unchanged step (sent every step!)
Composite = (Entry)+ <<0>>                ; >=1 changed entries, batched per step
Entry     = Line "\n" HexValue "\n"       ; mainline: trailing newline
Line      = HexToken (" " HexToken)*      ; the Locations.txt line, VERBATIM
HexValue  = hex, no prefix, u32
```

Ishiiruka's classic `Line "\n" HexValue <<0>>` (no trailing newline)
parses through the same path. The parser is **total**: junk frames,
non-UTF8 bytes, odd part counts all return `:error`, never raise
(fuzz-tested — a crash in the receive path kills the watcher
mid-session).

## Watch lines and semantics

- A line is a bare hex **virtual address** (`80479D30`) or a
  space-separated **pointer chain** (`804A0BC0 2` = `Read_U32(
  Read_U32(0x804A0BC0) + 2)`). A chain whose base is unmapped reads 0.
- **Addresses must be 0x80-prefixed virtual** on mainline. The classic
  2018 CSVs use bare offsets (`004D5F90`) — those produce ZERO
  traffic on this build.
- Every read is a **u32**. `get_f32/2` reinterprets the same 4 bytes
  as big-endian IEEE 754 (Melee is big-endian PowerPC), total over all
  bit patterns (`:nan` / `:infinity` / `:neg_infinity`, never a crash).
- `get/2` returns `:unknown` until the address **changes** after core
  start — for the RNG seed that's milliseconds, for a static address
  it can be never. Treat `:unknown` as "initial value not yet
  observed", or watch something that transitions.
- Dolphin echoes the Locations line **verbatim** as the datagram key,
  so the watcher normalizes (trim, collapse spaces) before writing the
  file — lookups break otherwise.

## The address book (`Melee.MemoryMap`)

NTSC 1.02 (GALE01 rev 2) only — version-guard anything new. Provenance:
classic libmelee `locations.csv` (altf4/libmelee `a086ea6~1`), itself
from the community RAM sheet (Salvato, achilles et al.).

Verified live on mainline (2026-08-22): `rng_seed` (804D5F90),
`menu_frame` (80479D60), `menu_state` (80479D30), and the **CSS
cursor block, re-derived by park-and-scan** (see below): the classic
4-port block relocated intact by +0x17200 (P1 bit-exact verified;
P2-P4 delta-derived, stride 0xB80 preserved).

Also verified live (2026-08-22c, the A/B toggle experiment with
screenshot ground truth): **`css_pN_selected`** (8043208C + 8·(N−1)) —
u32 = the port's locked-in EXTERNAL character id, `0x21` = none;
flips on A-select, back on B-deselect, untouched by hovering. P1
verified with fox (0x21→0x02), P2 with falco (0x21→0x14); a parallel
copy sits at +0x54. Decode with `MemoryMap.css_selected/1`. This is
the RAM replacement for the stream's dead `coin_down` (GOTCHA #101
and its offline sibling); the classic coin pointer chain
(`804A0BC0 2`) is DEAD on mainline. The hover byte `803F0E0A`
(per-portrait id) and status byte `803F0E08` live in the same
surviving static region.

**Two probe lessons from the same experiment** (they cost three
runs): `Probe.navigate!`'s default `until` is *arrival at the CSS* —
it does NOT pick the character; and against a free-running windowed
dolphin, button holds must be WALL-CLOCK (`press → sleep(250ms) →
release`), because `tap!`'s step-counted hold can complete in
sub-frame wall time when the console is merely polling — presses then
land nondeterministically, which mimics "buttons are dead".

**Two liveness caveats learned the hard way**: the RNG "canary" does
NOT tick at a settled CSS (it advances per random call, not per
frame) — use `traffic/1` deltas for liveness, never a value watch;
and a batch watch's composite datagrams reach ~20KB after scene entry
(the 64KB recv buffer exists because 2KB frames were silently
truncated and dropped whole).

### Park-and-scan (`examples/memory_scan_css.exs`)

When a heap object relocates, differential region-guessing loses to
reading the emulator's memory directly: the beam is dolphin's
ancestor, so yama permits `/proc/<pid>/mem`. Find MEM1 among the
descendants' >=24MB rw mappings — validate by demanding the KNOWN
scene word at +0x479D30, never a permissive check (a zero-filled heap
"validated" on the first attempt) — then park the cursor at a
stream-reported coordinate, scan for the exact f32 bit pattern, move,
rescan, intersect. Three passes nailed all five in-memory copies of
the cursor and the adjacent x/y struct pairs in one run.

### The `menu_state` scene word

`0x80479D30` holds the game's scene controller, four bytes:
`<<major, pending_major, previous_major, minor>>`. The Slippi menu
event's scene id is `(minor <<< 8) ||| major`, so
`MemoryMap.decode_scene/1` + `scene_name/1` reuse the stream parser's
whole taxonomy (`Melee.Events.Menu`). The pending/previous bytes are
RAM-only signal: `pending != major` = a scene change committed but not
yet landed. Byte-1/2 naming follows the community sheet; a live
transition trace confirming the order is still owed.

## Hunting a new address (the playbook)

When a classic address is stale (or you need something never mapped),
the watcher itself is the probe. `Melee.MemoryHunt` is the pure kit —
`candidates/3` (region → watch batch), `changed/2` (snapshot diff),
`correlated/2` (driven-minus-idle differential), `f32_class/1`
(stale-read triage), `tracks?/2` (commanded-coordinate confirmation) —
and `examples/memory_hunt_css.exs` is the live driver. The method:

1. **Batch candidates.** Locations.txt takes many lines — watch 50–100
   candidates per run, drive the game state you care about, keep the
   lines that change coherently. Bisect regions across runs.
   `tmp/mw_verify.exs` is the harness shape (`MW_SET` env selects
   sets).
2. **Command known values.** For cursors/positions, drive the state to
   a KNOWN coordinate (`Probe.goto!`) — a watch whose f32 tracks the
   commanded value is the answer. Idle animations make cursor movement
   free.
3. **Recognize stale reads.** Constants, denormals (`~1e-39` from
   `get_f32`), and values that never change while the real state moves
   are the signatures of a wrong address.
4. **Pointer chains from static roots.** Heap objects move between
   builds; static engine pointers (RAM sheet, decomp struct layouts)
   don't. Prefer `static_root offset...` chains over raw heap
   addresses — they survive build changes.
5. When live behavior defies hypotheses, **stop and write the
   contract tests** (HtDP input classes). The datagram-format battery
   found in minutes what live bisection missed for hours.

## Gotchas (each paid for)

| Symptom | Cause / fix |
|---|---|
| Zero traffic, everything `:unknown` | Bare classic offsets — 0x80-prefix them. Or no console pacing frames. |
| Black window, pre-video hang (mainline) | Missing `memory_card: true` (SlotA=255 write). |
| Real messages silently dropped | Parser expecting Ishiiruka format — mainline entries end `"\n"` before the NUL. |
| Datagrams truncated to ~1 byte under load | `recvfrom(sock, 0, :infinity)` — use finite timeout + explicit buffer (the module does). |
| f32 reads crash / read `4.7e-39` | NaN/denormal bits from a stale address — `get_f32` is total; treat denormals as "wrong address". |
| Values from lines you never registered | Stale `Locations.txt` in a reused home — kept under the raw line key, harmless. |

Debug: `MemoryWatcher.debug_info/1` (socket counters + raw-frame ring).
