# libmelee_ex — handoff / resume point

Written 2026-08-05, at the end of the session that built the port. Read
this first; it is the live resume point. Everything below is verified
unless it says otherwise.

## RESUME HERE (2026-08-21): THUNDER JACKET PROVEN, headless

The big one landed: the thunder jacket manifested and is pinned by
a green test ("thunder jacket" in tech_research_test.exs, `--only
dolphin_research`, 8/8 green). The user's tip was right — the
LEDGE-GRAB PKT2 interrupt is the method — plus two discoveries
nobody had written down: the release must come 11-16 frames after
the charge hit (a ~6-frame window; <=10 / >=18 never arm), and the
jacket rides NESS (CORRECTED by the user next session, then
position-logged: contact zap at gap ~7.5 from ness, ~20%, once).
Two open threads: a fresh yo-yo charge held while jacketed reads
ZERO (charging again clears/replaces the store — so "hold the
charge to keep the hitbox out" did NOT reproduce here; the user
implies there IS a keep-it-out method — ASK THEM / test their
answer), and manifestation is round-history-sensitive (armed-first
rounds read zero; control-round-first zaps; precondition unpinned).
Full recipe + mechanics in melee-tech.md items 2/5; probes in
tmp/jacket_ledgegrab_probe.exs (the proof), tmp/arm_map_probe.exs
(arming mapped frame-by-frame), tmp/jacket_bf_probe.exs (platform
landing = NEGATIVE, does not arm). New lore: aerial PKT actions
0x16A/B/C, PKT2 wall-bounce 0x16E, post-PKT2 fall is FallSpecial
(no DJ), CliffCatch 0xFC is input-immune (release at CliffWait
0xFD), BF spawns ness/falco ON the side platforms.

State: `Melee.Tech` 53 routines, NINE dolphin suites green; unit
suite 473 green; credo baseline 2/1/1; dialyzer 2. melee-tech.md
carries the per-round detail and the remaining catalog.

**Next follow-ups, in the order the user signalled:**

1. WINDOWED session candidates (user likes guiding these live):
   - Watch the jacket live (the electric graphic) — confirm the
     parked-at-ledge reading visually; also try touching the zone
     as ness re-approaches it himself.
   - Marth up-B ledgestall snap conditions (mapped, never grabbed).
   - Wall-band visual sanity check (nice-to-have; walljump/walltech
     are already proven on YS).
2. The still-unpicked pool remainder (melee-tech.md): fox shine /
   samus bomb stalls, ICs handoffs, chaingrab policies atop
   GameEvents, Zelda teleport edge-cancel, Luigi misfire (pairs
   with `custom_rtc` determinism), agility cancels, etc.
3. Main queue: Hex publish (still deliberately deferred), richer
   GameEvents follow-ons, real-hardware support.

`Melee.Stages.wall_segments/2` now carries the REAL per-stage wall
collision (from exphil's stage-.dat extraction, the same data behind
rewind_viewer.html). FoD's platforms start deterministically, so its
NIL proof is stable.

### Round summaries (2026-08-19/20), detail in melee-tech.md

1. Edge cancel — PROVEN as the wavedash slide-off (instant DJ out of
   the slip). CORRECTED 2026-08-20: aerial-landing slides clamp at
   platform edges only under a NEUTRAL stick; with the direction
   HELD through the landing lag the landing carries off the lip into
   an instant double jump — the pro-play drop-off input (user
   correction, live-verified).
2. No-impact land — PROVEN on Fountain of Dreams (its platforms
   sweep height continuously; a fixed platform is unreachable — the
   DJ apex grid is ~1.3 units coarse, measured). NIL = NO Landing
   action at all + 0-frame actionability.
3. V-cancel — PROVEN: falco drift-hops into fox's fixed-KB SHINE;
   press_frame 45 = 94.3% travel; earlier presses airdodge and whiff
   (self-labelling sweep).
4. Ness PKT2 self-hit — PROVEN (`:pkt2` steer plans; bolt turns
   6 deg/f, r~19, dies on floors, and Slippi's item stream can
   silently stop reporting a LIVE bolt — trust hitlag). The thunder
   JACKET: the cracked recipe (charge hit -> clean release -> PKT2)
   is now verified per-component and STILL doesn't manifest —
   remaining levers: a non-grazing self-hit aim and the mid-flight
   PKT2 interrupt (BF platform / ledge grab). See melee-tech.md.
5. Walljump + walltech — PROVEN 2026-08-20 on Yoshi's Story after
   importing the REAL wall geometry (exphil's stage-.dat collision
   extraction) as `Melee.Stages.wall_segments/2`: FD/PS have almost
   no wall below their lips (10.5 / 4 units — hangs sit BELOW), YS's
   flanks are wall to the depths. Plain walljumps play action 0xCB
   (the WallTechJump id); walltech via dair-spiked hang at tumble
   percent + double-stick ASDI into the wall.
6. ICs wobbling — PROVEN: 9-move 21% single conversion. Two
   mechanics pinned: stick throws fire on EDGES (park the down in
   CatchPull), and grab damage carries last_hit_by=0 on the wire —
   `Melee.GameEvents` now infers the grabber as attacker.

New test-side lore (now encoded in helpers): walks TEETER at every
lip (escape by dashing); teeter/knockdown/ledge-hang idle FOREVER on
a released stick (settle helpers nudge); walking one character
through another bulldozes the victim (park the far actor first).

POOL ROUND SHIPPED (2026-08-20, `--only dolphin_pool`, 7 tests):
phantasm + shortening (falco's side-B rides 0x15B-0x15D, NOT the
enum's fox slots; shorten frame 14 = 60.5 -> 11.0 travel; B-mashing
EXTENDS it to 81), ledge-cancelled phantasm off the BF platform,
haxdash (42f regrab, intangibility refresh asserted), falco
ledgehop double laser (3 lasers), pivot grab, boost grab (25.1 vs
2.1 slide), yoshi DJ armor (damage taken, no damage ACTION — never
measure armor by height, the DJ rise poisons it). Marth up-B
ledgestall descoped with a map (the slash's rise never
ledge-grabbed, both facings); `:ledgestall` ships unit-tested.

Methodology notes (still true, hard-won): lag = ACTIONABILITY,
never idle animation length; sweep frame offsets (the game is
deterministic); MAP failures frame-by-frame before re-sweeping
(action/position traces in the fold); settle to STANDING 0x0E;
recenter between attempts; launcher tests need
`boot_rules: [stock: 99, time_limit: 99]`; positioning order
matters (park the FAR actor first, compute targets from FRESH
positions — stale-position walks bulldoze); a bystander within ~44
of a PKT cast eats the bolt; Slippi's item stream can silently stop
reporting live items — trust hitlag/actions over item visibility.

Checks before each commit: `mix format`, full `mix test` (472
green), the touched dolphin suites, `mix credo` (baseline: 2
refactoring / 1 readability / 1 design), `mix dialyzer` (Total
errors: 2).

## Addendum 2026-08-17 (second session): rules menu SHIPPED

The in-flight rules work below is done, entirely headless (no windowed
session needed — the never-read screenshots plus `menu_selection`
sufficed). `Match.play(rules: [stock: 1, time_limit: 5,
team_attack: false, pause: false])` sets the Custom Rules screen on
the way in; `--only dolphin_rules` (3 tests, ~24s) proves it; the full
mechanics + GAME_START offsets are in melee-menus.md "Custom Rules".
New GameState fields: `timer`, `is_team_attack`, `pause_enabled`
(+ `Events.Parser.game_start_raw` for future byte-diff discovery).

Corrections to the notes below, all found behaviorally
(`tmp/ta_probe.exs`):

- **Team Attack defaults ON on these builds** (not OFF as assumed;
  vanilla Melee defaults OFF — expected on reflection: competitive
  doubles is always played TA ON, so Slippi shipping that default
  makes sense). It is
  Additional Rules row 1, GAME_START 0x6 bit 0. The first "verify by
  ally damage" attempt used Fox's shine, which hits allies for 5%
  even with TA OFF (a real Melee exception, like grabs) — a normal
  hitbox (dash attack: 9% vs 0.0%) discriminates it.
- Additional Rules row 2 is **Pause**, 0x7 bit 3 (set = disabled).
  Turning it off breaks `Match.quit` (LRAS rides the pause menu) —
  that's how it was identified, and it's now a documented rules
  option for stray-START-proof training episodes.
- The rules screens (submenu 13; sub-screens report 0xFF) wrap both
  ways and navigate cleanly headless; values are set open-loop from
  fresh-session defaults (STOCK mode / 4 stocks / 8:00 / TA ON /
  Pause ON) and verified from GAME_START. Rules persist per session:
  `rules:` on the FIRST play only (else `:rules_need_fresh_menu`).

**Items: DONE later the same day.** The Item Switch sub-screen is
mapped (two columns, cells 0-30; the frequency dial is selection 31
and 32 — same dial from both columns) and productized:
`rules: [item_frequency: :very_high, items: [:poke_ball]]`. Key
facts: items default OFF (frequency 0xFF at GAME_START 0x10); the
5-byte mask at 0x28..0x2C has **bit index == item id** (proved by a
31-cell byte-diff sweep + isolated-cell spawn identification: food /
bob-omb / metal box spawned alone as predicted); containers (ids 0-3)
aren't switchable; `Melee.Enums.ProjectileType` now names the whole
common-item block 0x00-0x22; new GameState fields `item_frequency` /
`item_bitfield`. The Poke-Ball-only integration test observed spawn
set exactly `[0, 1, 2, 34]`. The debug-menu (DBLEVEL MASTER)
question is still open.

## Addendum 2026-08-14

- **CSS coordinates measured live for ports 2-4** (`Melee.Probe`
  sessions, netplay windowed). Headline: the name box is **15.4**-spaced
  (slider pitch), not 15.82; pinned tag-list columns at exactly
  `-25.2 + 15.4*(N-1)`. Two new traps documented in `melee-menus.md`:
  a CSS panel is inert (N/A, `controller_status` 3) until the port
  locks a character; CSS fields stop updating past the CSS, so
  cross-port gates may only bite at the CSS.
- **Elixir-native by default:** `Melee.Transport.EnetBeam` is the
  default transport; the Rustler crate compiles only with
  `MELEE_BUILD_ENET_NIF=1` (prebuilt priv .so loads otherwise). Plain
  `mix test` needs no Rust.
- **Nametag select test fixed and live-verified** (create 8.1s,
  select 10.6s): the nametag flow must be sequenced after CPU config
  (keyboard interruption yanked the port-2 hand off the slider,
  9 became 8), and its gate must apply at the CSS only. `Probe.stop/1`
  is crash-tolerant now (a killed Dolphin no longer leaks the emulator).
- **ExiAI nametag bug: SOLVED via card seeding.** Root cause: scene
  0x28 (the boot scene) holds the "Create Game Data?" prompt on
  netplay but never appears with a prompt on ExiAI, so an ExiAI
  GCI-folder card never gets save data and nametag flows ran
  vacuously (the intermittent disconnect was secondary). Fix:
  `memory_card: {:folder, seed: path}` copies a known-good `.gci`
  into a fresh card (never clobbering); a netplay-created save with
  the EXPH tag is committed at
  `test/fixtures/01-GALE-SuperSmashBros0110290334.gci`. The select
  test now seeds and runs on **ExiAI, headless, ~5s, no window**
  (`--only nametag_select`); only the create test (`--only
  nametag_create`) still needs the windowed netplay build, because
  answering the boot prompt is the thing it tests.
- **Fixed since:** Dolphin's death is now visible
  (`Melee.Dolphin.watch/2`, stderr captured, output tail in the exit
  log; `Melee.Session` logs the tail too); a dead controller pipe
  latches gracefully instead of crash-cascading (`flush/1` returns
  `{:error, {:pipe_closed, reason}}`); boot scene `0x28` is typed
  `:boot_splash` and waited out (it auto-advances; A-pressing it was
  how runs wandered into Online Play).
- **Docs:** `docs/getting-started.md` (with smoke-test catalog) and
  `docs/behavior-testing.md` (capability catalog, semantic edges,
  improvement roadmap) added and wired into ex_doc.

## Addendum 2026-08-17: doubles shipped; rules menu IN FLIGHT

**Doubles is done, three layers deep** (commits through `5287c01`):
`Melee.Cursor` (steering + settled-press primitives, promoted from
Probe); `Match.play(teams: true, pN: [team: :blue])` (phased flow:
coins down -> mode toggle -> color chips -> ready_to_start gate);
`Bot.run_many/2` (several bots in one match, each with its own
act/3 + controller; any bot returning `:quit` LRAS-ends the episode);
`GameState.allies/2`/`enemies/2`. All live-verified in
`--only dolphin_teams` (2v2s via Match.play, Bot.run, and two bots via
run_many). Teams mechanics in melee-menus.md "Team Battle". Speed
facts: windowed = exactly 59.9fps (the "slowness" at match start is
the game's pre-GO countdown, frames -123..-1); headless ~450fps with
blocking pipes and the BEAM handshake (~2.2ms/frame) is the ceiling —
emulation_speed is irrelevant under blocking. The nix
cargo/rustc/gcc wrapper is NOT needed for anything (plain mix works).

**IN FLIGHT: the rules menu** (nothing committed yet, probes in
repo tmp/ — rules_probe.exs / rules_windowed.exs (the session scratchpad dies with the session)). Goal: set Team
Attack (user plays it ON; game defaults OFF), stock count (1-stock =
~4x RL episode throughput), timer, items. Facts established so far:

- VS Mode menu (menu 5, submenu 2) rows by menu_selection: 0 Melee,
  1 Tournament Melee, 2 Special Melee, 3 CUSTOM RULES, 4 Name Entry;
  wraps. List navigation = stick-down EDGES (2 frames tilt, ~12
  release); Melee list menus act on edges, key-repeat after ~15f.
- A on row 3 ENTERS Custom Rules: `menu=5, submenu=13` (the
  custom_rules_submenu enum id!) with menu_selection tracking rows —
  so rules NAVIGATION is fully observable headless. Row values are
  presumably NOT in the gamestate; plan was: set values open-loop
  (left/right edges), verify via GAME_START (stocks/timer are in the
  game-info block; find the team-attack bit empirically by diffing a
  written replay's GAME_START bytes with the setting on vs off, then
  expose it like is_frozen_ps). Screenshots of the rules screen are in
  repo tmp/rw2_rules*.png — READ THEM FIRST, they were taken but
  never inspected before the context handoff.
- **DISCOVERY: the game runs in DEBUG MODE — DBLEVEL: MASTER.** VS
  menu row 1 ("Tournament Melee") opens Melee's debug menu (raw scene
  0x0006: DATE FEB 13 2002, VERSUS MODE >, MODE TEAM TEST >, GLOBAL
  DATA EDIT >, DBLEVEL MASTER). This finally explains the "4-man
  survival test!" CSS banner (debug-mode label). Why DBLEVEL is
  MASTER is unexplained (both builds, plain gecko set) — worth
  understanding; the debug VERSUS MODE submenu is itself a rich match
  config surface (and possibly a way to turn debug off).

Working style that works: headless for verification/regression,
WINDOWED for UI discovery with the user watching — they guide in real
time and repeatedly cracked what blind probing could not (the token
rule, the toggle location, "you're too far left"). Ask before
windows; warn what will appear.

Next after rules: Hex publish; tech-skill primitives (Melee.Tech);
richer GameEvents (combos/openings); EXI direct channel exploration;
real-hardware support (the one Python-libmelee parity gap).

## Addendum 2026-08-16 (third session): the smoke-test sweep

Nine new windowless ExiAI smoke tests (catalog in getting-started.md):
`dolphin_roster` (25/25 portraits + Sheik + Frozen paths), `dolphin_replay`
(live game == Slippi's own recording, 74 shines both sides),
`dolphin_pool` (3 concurrent matches, 3.2s), `dolphin_projectiles`
(fox lasers live), `dolphin_ics` (Nana 300/300 frames), `dolphin_analog`
(round-trip is the IDENTITY — Melee's calibration inverts
fix_analog_stick; deadzone = sent [0.4, 0.6] -> exact neutral),
`dolphin_4p` (four ports in-game + live Session|>GameEvents pipeline),
`dolphin_cpu` (slider 1..9 up and 9->3 down), `dolphin_stages`/`dolphin_tech`
from the prior batch. Three real bugs found by writing them:
portrait hitboxes don't fill the grid cell (Roy read as LINK;
select_character now requires hover confirmation before pressing A);
:costume is Slippi-online-CSS-only (documented; local CSS ignores it);
and the KO/SD classifier's hitstun_frames_left clause misread misc_as
union junk as hitstun (action states are now the only signal — the
fixture's 27% death correctly reclassifies to :sd).

## Addendum 2026-08-16 (second session): the capability batch

Six queued items, all landed:

1. **Multishine smoke test** (`--only dolphin_tech`): frame-perfect
   input proven live — 74 shines / 600 frames at the theoretical
   8-frame cycle, deterministic. Enemy matters: idle human dummy, not
   a CPU (a level-1 walked over and broke the loop).
2. **`Melee.Match` + `Melee.Bot`**: the high-level API. `Match.play/2`
   = boot-to-match with every coordination gate encoded; `Melee.Bot` =
   one-callback bots; `--only dolphin_match` plays a full game through
   the public API alone. `examples/multishine_bot.exs`.
3. **Savestate spike: dead end** on current builds (no CLI flag on
   ExiAI/netplay; mainline has `-s` but is windowed-only). Menus, not
   boot, are the remaining overhead (ExiAI boots in ~0.2s).
4. **Multi-game** (`--only dolphin_multigame`): 3 games, one Dolphin,
   ~4.7s of menus between games.
5. **Stage-select coverage** (`--only dolphin_stages`): all six legal
   stages live-verified (previously only FD), via `Match.quit/3` — the
   LRAS quit-out API. Three live-found facts: the quit is Start EDGES
   with L+R+A held (a chord hold never fires); pause is locked out
   until frame 0; a paused game emits NO spectator frames, so nil
   polling steps are normal mid-quit and must consume the frame budget
   (a frozen pulse counter deadlocked).
6. **Event streams**: `GameEvents.stream/1` (finish flush built in) +
   `Session.stream/2` — replay-or-live scoring as one pipeline.

## Addendum 2026-08-16

- **Peppi differential extended to pre-2.2.0 replays** (exphil
  `ef35986`): all 9,092 old corpus files through `Melee.SlpFile`,
  **9,087 OK / 0 divergences** (5 skips = peppi's own Rust panics).
  Found and fixed here: the final frame of GAME_END-ending old replays
  was dropped (`83bcc6a`), and a duplicated (early-rollback) frame was
  silently merged instead of treated as a re-simulation boundary
  (`f278bfa`). Byte-verified along the way: peppi fabricates and
  misassigns rows over old Slippi's mid-game port write-gaps; this
  codec matches the raw exactly there. `GameEvents.finish/1` added for
  end-of-stream `:game_end` (`21b72c1`).

## What this is

An Elixir port of [libmelee](https://github.com/vladfi1/libmelee), the
API for writing Super Smash Bros. Melee AIs that work with Slippi.
Repo: `github.com/blasphemetheus/libmelee_ex` (public). Consumed by
[exphil](https://github.com/blasphemetheus/exphil) via a path dep
(sibling checkout) — the same pattern edifice uses.

**Parity target: vladfi1's fork (~v0.47).** Upstream `altf4/libmelee`
was archived January 2026. A full v0.43→v0.47 audit found **zero
wire-format changes**, so the port's event/protocol layer is current by
construction.

## State

- `mix test`: 94 doctests, 3 properties, 281 tests, 0 failures
  (7 excluded: `:dolphin` integration tags).
- `mix credo --strict`, `mix dialyzer` (0 errors), `mix format --check`
  all clean. CI at `.github/workflows/ci.yml`.
- exphil runs entirely on this library — **the Python `melee_bridge.py`
  is out of the live-play loop.**

### What is verified, and how

| Claim | Evidence |
|---|---|
| Event codec is correct | **Differential vs peppi**: 2,625 replays, 19.1M frames, ~1.34 **billion** field comparisons, zero divergences (34 fields/player-frame). Plus a no-crash sweep over 10,847 replays |
| Bridge matches Python exactly | `exphil/scripts/parity_harness.exs`: same input schedule through both bridges, 1800 frames, **zero field mismatches** (max float delta 3e-8) |
| Live play works | Production policy `ms_g10b_human` played a full 8-min game through the native bridge: 28,924 frames to GAME_END, 1080 shine entries (~134/min) |
| Both transports work live | `mix test --only dolphin` passes over `EnetNif` and `EnetBeam` against real Dolphin |
| Netplay Direct works | Two accounts, real matchmaking, 600 frames/side, own_port correctly resolved the *asymmetric* assignment (EXPH#288→2, DBTD#411→1) |
| Nametag works | `mix test --only dolphin_nametag` from a wiped home: create 8236ms (90KB save written), select 11043ms with `nametag == "EXPH"` from GAME_START |
| Controller math matches Python | Analog quantization asserted float-exact vs Python libmelee, including banker's rounding |

## Environment (NixOS, host `nixos_slanka`)

```sh
# libmelee_ex — Rust is needed for the ENet NIF
cd ~/git/libmelee_ex
nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc --command mix test

# exphil — MUST be inside devenv (EDIFICE_LOCAL_NX, make, CUDA)
cd ~/git/exphil
devenv shell -- bash -c "EXPHIL_SKIP_NIF_COMPILE=1 mix test"
```

- **Never run bare `mix deps.get` in exphil** — it swaps the local
  nx/exla forks for hex packages.
- `EXPHIL_SKIP_NIF_COMPILE=1` is required in exphil: the `ethnum` crate
  fails under rustc 1.97 (documented in `peppi.ex`); the prebuilt `.so`
  is used instead.
- Integration tests need `MELEE_DOLPHIN_PATH` and `MELEE_ISO_PATH`.
  ISO: `/home/blewf/isos/melee.iso`.

### Dolphin builds — they are not interchangeable

| Build | Path | Use for |
|---|---|---|
| netplay-stable | `~/.local/share/slippi/netplay/Slippi_Online-x86_64.AppImage` | **Netplay Direct** (the only one where it works), windowed menu work |
| ExiAI Ishiiruka (flush-patched — the DEFAULT since 2026-08-18) | `~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless` | headless local games, EXI inputs; ~1.76ms/frame vs stock's 2.1 (docs/throughput.md) |
| ExiAI Ishiiruka (stock, fallback) | `~/.local/share/slippi/exi-ai/dolphin-emu-headless` | same jobs, unpatched upstream binary |
| mainline | `~/.local/share/slippi/mainline/dolphin-emu-mainline` | analog-through-pipes; its extracted AppImage lacks a headless Qt plugin |

**Slippi Direct does NOT work on the ExiAI build** — verified against a
Python libmelee oracle that froze at the identical spot. Use
netplay-stable with `gfx_backend: "Null"` (or `"OGL"` to watch).

### Hard-won Dolphin gotchas

- **Menu events require gecko codes.** The `0x3E` menu event only exists
  when libmelee's `GALE01r2.ini` "Extract Menu Info" code is installed
  (`Melee.Dolphin` does this by default). Without it a session hangs
  frameless in menus.
- **Memory cards hang boot.** A card whose data Melee doesn't recognize
  opens "Create Game Data?", a nameless scene no navigation answers.
  `Melee.Dolphin` disables cards by default; `memory_card: :folder`
  provisions one properly. `memory_card: true` only *preserves* existing
  config — it does not plug a card in (this silently lost the first
  nametag).
- Spectator config keys differ by flavor: Ishiiruka `[Core] Slippi*`
  vs mainline `[Slippi]`.

## Design conventions (follow these)

- **Raw integer wire values in structs** — internal ids, not atoms
  (Fox = `0x01`, FD = `0x19`). `Melee.Enums.*` convert for readability.
  Buttons are atoms (`:a`, `:main`). Getting external vs internal stage
  ids confused cost real debugging time.
- **HtDP design recipe** (the user's standing preference): data
  definitions → `@spec` + purpose `@doc` → worked examples (doctests) →
  template → definition → tests. Write the examples *before* the code —
  doing it backwards produced a wrong doctest and a false property.
- Lots of tests, and prefer tests that can't pass vacuously: golden
  values generated from the Python implementation, timing/frame guards
  on live tests, differential comparison over assertion-by-eyeball.

## Module map

| Module | Role |
|---|---|
| `Melee.Console` | connect + `step/2`, frame queue, controller flush ordering, opt-in reconnect |
| `Melee.Session` | supervised Dolphin + console + controllers, correct startup order |
| `Melee.Events` (+ `.Menu`) | pure Slippi binary decoder — the heart |
| `Melee.Slippstream` | spectator JSON message codec |
| `Melee.Controller` | named-pipe protocol + analog quantization |
| `Melee.MenuHelper` | menu navigation, CPU config, direct codes, **nametags** |
| `Melee.Dolphin` / `.DolphinConfig` | process + user-dir/config management |
| `Melee.Transport{,.EnetNif,.EnetBeam}` | swappable ENet (Rust NIF / pure BEAM) |
| `Melee.GameState`/`PlayerState`/`Projectile` | per-frame snapshot |
| `Melee.FrameData` | attack/hitbox/physics queries (framedata.py port) |
| `Melee.Probe` (test/support) | live-driver harness for menu work |

Docs: `docs/melee-menus.md` (measured menu mechanics), `README.md`.

### Replays older than v2.2.0 (handled by Melee.SlpFile)

`Melee.Events` completes a frame on FRAME_BOOKEND (`0x3C`), which Slippi
added in replay **v2.2.0** — same as libmelee. Older replays parse to a
clean `:game_end` with **zero frames**: silently empty, not an error.
That is ~91% of the huggingface corpus (9,092 of 9,995). Irrelevant for
live play (the spectator stream is always modern) but it means this
codec alone is **not** a bulk-ingestion path for old replays — but
`Melee.SlpFile` handles them via libmelee-style manual bookends (400/400
 verified), and peppi remains the bulk parser. `ExPhil.Data.Parity.comparable?/1`
 screens for the raw-codec case.

Note this also means an early "10,847 replays parsed" sweep was weaker
evidence than it looked: many of those files contributed no frames. The
peppi differential is the real correctness evidence.

## Verification lessons (do not relearn these)

1. **Verify a commit in a worktree, never a working tree an agent is
   editing.** I declared the nametag branch broken after testing a
   mid-flight tree; the fixes were already in the commit. `git worktree
   add <tmp> <sha>` and test there.
2. **`Melee.Probe` step counts are console steps, not emulated frames** —
   polling coalesces them. Use `Probe.elapsed_ms/1` for timing guards.
   (231 "frames" was 8.2 real seconds.)
3. Live "it worked, I saw it" reports need independent reproduction
   before merging; unit-test claims do not.

## Fixed: decoder crash on a bad port byte

`mix test --seed 777` used to fail the "parser never crashes garbage"
property — `pre_frame`/`post_frame` read the port from a `u8` and index
4-slot metadata tuples, so a corrupt stream raised
`:erlang.element(186, {1, 2, 0, 0})` and would have taken a live console
down mid-game. Fixed by dropping events with a port outside `1..4`, with
a regression test. A good advertisement for keeping the fuzz property.

## Next work — the queue (set with the user 2026-08-17)

Hex publish is deliberately DEFERRED — not shipping yet. Priorities,
in the order agreed:

1. **Training throughput.** PROFILED 2026-08-17 — full numbers and
   method in `docs/throughput.md`. Verdict: the BEAM side is
   exonerated (0.03% busy; 2.2us JSON decode; input pre-buffering
   changes nothing); the 2.1ms blocking frame is Dolphin-side
   scheduling — every packet arrival is one or two periods of a
   ~1.06ms clock (the spectator server's ~1ms enet_host_service
   loop), and blocking always spans two. Remaining moves, in order:
   (a) scale OUT — sessions stack near-linearly (4 concurrent =
   1830fps aggregate at ~86% efficiency on 32 cores), so the pool is
   the cheap win today; (b) DONE — the ExiAI spectator loop is
   patched (local branch `spectator-flush-on-frame` in
   `~/git/slippi-Ishiiruka`, binary installed at
   `~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless`):
   p50 2119 -> 1755us, p99 3216 -> 1856us, 4-concurrent 1830 -> 2117
   aggregate, all integration suites green on it. The step is now
   EMULATION-bound, so the next per-instance lever is Fizzi's
   fast-forward gecko (what slippi-ai uses), not transport. ALSO DONE
   (2026-08-18): `exi_inputs:`/`ffw:` launch options enable the ExiAI
   build's Bot-Input-Overrides + FFW geckos — blocking step p50 233us,
   ~4272fps solo, ~11.8k aggregate at 4 (high variance; see
   docs/throughput.md), multishine frame-perfect through the EXI input
   path (`--only dolphin_ffw`); analog triggers are dropped on it;
   (c) the EXI DIRECT CHANNEL — STAGE 1 DONE (2026-08-18): events out
   over a unix domain socket written from the game thread at DMAWrite
   time (`direct_channel: true` on Session/Dolphin/Probe;
   `Melee.Transport.Direct` + Console `protocol: :raw`; Dolphin side
   on the same Ishiiruka branch, config key SlippiDirectChannelPath).
   p50 192us, ~5058fps solo, ~12.6k aggregate at 4; multishine
   frame-perfect over it (`--only dolphin_direct`), whole test 630ms.
   STAGE 2 ALSO DONE (same day): `direct_inputs: true` — lockstep pad
   batches over the channel serving CMD_OVERWRITE_INPUTS (the input
   poll blocks on a fresh batch); p50 206us, multishine frame-perfect
   through the duplex path (`--only dolphin_direct_inputs`), analog
   triggers carry (the old "ExiAI drops analog triggers" gotcha is
   INVERTED on this build: pipes/SI is the lossy path now — fix
   exphil GOTCHAS #66 accordingly). Pipes still pace menus; retiring
   them fully would need menu inputs over the channel — only bother
   if fifo plumbing ever hurts. Cross-run determinism now hinges on
   RNG-seed control (item 7): lockstep fixed input alignment. shm
   remains not-worth-it. Do NOT
   spend effort on BEAM-side protocol changes. The branch is pushed:
   github.com/blasphemetheus/slippi-Ishiiruka `spectator-flush-on-frame`
   (a PR to vladfi1 remains an option). The FULL `--only dolphin`
   gauntlet passes on the patched build except the two structurally
   environmental tests (DolphinTest's manual-Dolphin connect test and
   nametag_create's netplay-only boot prompt); nametag_select's
   anti-vacuous floor was retuned to 1s because the patched build
   finishes the whole flow in 1.2-1.8s (was 2.9s). DONE 2026-08-18:
   exi-ai-flush is the default ExiAI path in every doc and test
   moduledoc; stock remains at `exi-ai/` as fallback.
2. **Card-seeded rules — DONE via a better mechanism (2026-08-18).**
   Card seeding itself is NOT viable: Slippi's `$Required: General
   Codes` gecko-write the default-rules template at 0x803D4A48 every
   boot (Stock Mode / 4 Stocks / 8 Minutes / No Items [Magus]), so a
   card's saved rules load and are immediately overridden (verified
   with a harvested rules card). Those same writes also explain the
   Stock/4/8:00 defaults AND the Team Attack-ON default (byte 1 of
   Magus's "8 Minutes" word). The shipped replacement:
   `boot_rules: [stock:, time_limit:, team_attack:, pause:,
   damage_ratio:, item_frequency:]` on Dolphin/Session emits our own
   template-override gecko (user-ini codes run after Sys, so ours
   win; menu `rules:` still overrides in-session) — every match
   starts pre-configured with ZERO menu taps and no memory card.
   Template layout decoded + documented in melee-menus.md
   "Boot-default rules"; `--only dolphin_rules` gained the zero-tap
   test. Card seeding remains the nametag mechanism only.
3. **`Melee.Tech` — TIER 1 SHIPPED (2026-08-18).** Pure per-frame
   state machines (`step/2` returns commands — unit-testable without
   an emulator; `step/3` applies to a controller), timed off a
   compiled-in per-character NTSC jumpsquat table (libmelee's CSVs
   lack it). Implemented + live-verified (`--only dolphin_movement`,
   ~15s): short/full hop (apex 3.97 vs 7.13), wavedash (8/8 special
   landings, 21.1 travel, byte-repeatable), banded dash dance (an
   OPEN-LOOP dance drifts — walked Fox off FD's edge; the routine is
   closed-loop around its origin), SHFFL with pulsed L-cancel
   (landing lag 6 vs 14 in the identical no-L control — the pulse
   trick: a 6-frame L period guarantees an edge inside the 7-frame
   window without predicting the landing), multishine (37/300
   frames, Fox+Falco via the jumpsquat table). TIERS 2+3 ALSO SHIPPED
   (same day): fast_fall, waveland, pivot, tech (unit-pinned; live
   proof needs a scripted launcher), ledgedash (grab -> DJ above the
   lip -> dodge in, lands WITH galint; two dead foxes taught that
   dodging from below dives and from beside hits the stage wall),
   waveshine (4/4 into wavedash-outs), short_hop_laser (projectile
   observed), djc_aerial (Ness nair at apex 2.91). The ledge-grab
   test setup composes the primitives themselves: pivot + backward
   wavedash off the edge. TIER 4 + MEWTWO SHIPPED (2026-08-18):
   `:di`/`:sdi`/`:asdi_down` proven A/B against control runs under a
   scripted port-2 falco up-smash launcher (`--only dolphin_defense`:
   SDI slid 22.7 units during hitlag vs 0.0; DI bent knockback dx to
   −9.2 vs 0.5), which also delivered the deferred LIVE `:tech` proof
   (0xC7 on a 58% launch — the arming check had to read
   speed_y_self + speed_y_attack; knockback's fall speed is all in
   the attack component). Mewtwo kit (`--only dolphin_mewtwo`): DJC
   nair apex 2.72, `:shadow_ball_charge`/`:shadow_ball_fire` (state
   map learned by trace: 0x157 is a NON-exiting full-charge hold
   loop, 0x158 shield-store, 0x159 release; B with a stored charge
   RESUMES, firing needs a second B edge), `:teledgehog` (turn away —
   falls only grab ledges they FACE — hop out past FD's lip at
   ±85.57, hug stage-ward, CliffCatch 0xFC; up-teleport kept as the
   deep-miss fallback). Launcher tests need
   `boot_rules: [stock: 99, time_limit: 99]` — Melee's factory
   default is a 2-minute TIMED match and FFW blows through it
   mid-test. BACKLOG CLEARED (2026-08-19), 17 more routines in three
   batches, all live-verified:
   `--only dolphin_universal` (fox trot, moonwalk A/B'd by dash-end
   velocity, wavedash OOS, shine turnaround into 0x16C, drillshine
   gap 9f, JC grab = standing Catch out of a dash, crouch cancel
   peak 0.0 vs 9.59, powershield GuardReflect on a tracked laser,
   shine grab chain, shield drop through a BF platform, Yoshi egg
   shield mapped to 0x156/0x159, falco SH double laser);
   `--only dolphin_characters` (Peach float + float-aerials
   0x158..0x15C, Falcon gentleman jab3-no-rapid + instant RAR,
   Marth pivot fsmash, Samus SH missile + the measured fact that
   landing inside ANY special anim is a ~30f heavy landing, ICs grab
   desync: Nana blizzards solo while Popo holds — her 6-frame-late
   grab whiff must end before the B). What remains in
   docs/melee-tech.md is research-grade: Peach's folkloric 40% FC
   (did not reproduce, measurements recorded), Samus edge-cancelled
   missile / bomb jump / grapple, ICs handoffs, tipper SPACING,
   Yoshi parry intangibility pin, Mewtwo teleport-cancel, thunders.
   DI mixups/tech-chase POLICY belongs atop GameEvents. EXOTIC
   ROUND (2026-08-19): the landing-ANIMATION-vs-LAG artifact found
   and fixed (lag = ACTIONABILITY, probe a held movement input) -
   which flipped two verdicts: Peach FLOAT CANCEL is REAL (2 frames
   actionable vs 13/16 controls) and Samus MISSILE CANCEL is REAL
   (2 frames); plus Samus SUPER WAVEDASH proven (:super_wavedash,
   126.4 units at flick_frame 39) and the Ness YO-YO GLITCH
   reproduced (stale usmash hitbox re-activates at 28.8 units,
   37 frames later, mid-charge-hold; requires the victim walking in
   and HOLDING toward through the knockback). RESEARCH
   ROUND (2026-08-19, --only dolphin_research): Mewtwo teleport
   EDGE-CANCEL proven (end anim slides off FD lip -> double jump out
   of the fall; grounded teleport = 55.2 units, 29f end anim); Marth
   tipper proven via FrameData.range_forward spacing (18.2 vs 14.0,
   victim body width offsets contact); thunders combo (:uthrow_uair)
   proven THROUGH GameEvents as one 18.7%/5-move conversion (throw
   edge must land in CatchWait, uair must ride the jump, pop
   out-races the 26f throw anim only at ~40%+); Peach 40% FC did NOT
   reproduce across the full input matrix (docs/melee-tech.md) - the
   l_cancel byte never fires.
4. **Richer `GameEvents` — SHIPPED (2026-08-18).** Four new
   post-frame fields (last_attack_landed 0x1E, combo_count 0x1F,
   last_hit_by 0x20 wire-0-based -> ports, l_cancel 0x33) feed two
   new events: `{:l_cancel, %{port, success}}` (one per aerial
   landing, read at landing-action entry) and `{:conversion, ...}` in
   the slippi-js ConversionComputer mold — opens on attributed damage
   (last_hit_by, no heuristics), moves carry the attacker's
   last_attack_landed, closes on 45 actionable frames / death /
   game end, openings classified neutral_win / counter_attack /
   trade. `Melee.GameEvents.Stats.summarize/1` folds streams into
   per-port kills, openings-per-kill, damage-per-opening, L-cancel
   rate, SDs. Verified three ways: synthetic unit sequences; the
   multishine FIXTURE replay turned out to contain 9 real conversions
   + 1 L-cancel (golden test now pins them — incl. the nuance that
   conversion did_kill means "died inside the punish window" and can
   disagree with stock_lost's SD/KO trajectory call, both correctly);
   and live (`--only dolphin_conversions`): Tech SHFFLs Falco, 2/2
   L-cancels confirmed by the game's own byte, one 12% conversion
   attributed. Not done: slippi-js corpus differential (needs node),
   tech-situation events, recovery outcomes — natural follow-ons.
5. **Special Melee — EXPLORED, blocked on Slippi itself (2026-08-18).**
   Everything is mapped and drivable (per-mode scene majors typed in
   Melee.Events.Menu, open-loop CSS/SSS recipes, matches verifiably
   start and play — windowed frame dumps), BUT special-melee scenes
   emit ZERO game events: the Slippi recording gecko only instruments
   VS/online scenes (measured: 300 in-match packets, all menu 0x3E).
   No GAME_START, no frames -> nothing for a bot to observe. Full
   findings in melee-menus.md "Special Melee". UNLOCK: extend
   slippi-ssbm-asm's recording scene gate to these majors (fork-level
   ASM work) — everything else is already in place. Also note two
   traps found: special CSS/SSS readbacks lie (selection works but
   coin/cursor fields stay blind), and gamestate.stage's FD DEFAULT
   makes stage "readbacks" vacuous without a GAME_START.
6. **DBLEVEL MASTER mystery — SOLVED (2026-08-18).** Two lines in
   Slippi's `$Required: General Codes` (Sys GALE01r2.ini) remap the
   Tournament Melee row to Melee's debug menu (`0422D638 38000006` —
   the immediate is scene 6, exactly the raw_scene observed) with an
   Achilles patch making exit land at the CSS. DBLEVEL MASTER is the
   menu's retail-default display, not a debug mode. The debug menu is
   a gamestate BLACK BOX (menu_selection/submenu freeze — its own
   cursor variables), so it is useless as a headless config surface;
   accidental entry is benign (B exits to a fully working CSS —
   live-verified to a match). Full writeup in melee-menus.md "The
   debug menu behind Tournament Melee". Nothing to build.
7. **RNG control — DONE (2026-08-18).** Bit-reproducible episodes via
   `single_core: true` + `custom_rtc: <unix seconds>` (+ lockstep):
   Melee derives its local seed from emulated boot state, so the RTC
   IS the seed selector — same RTC = identical seed + identical
   300-frame fingerprint including item spawns; RTC+1 = a different
   match. `--only dolphin_determinism` (~10s) is the proof;
   `gamestate.random_seed` (GAME_START 0x13D) is the readback; recipe
   and findings in docs/throughput.md "Reproducible episodes".
   Single-core costs nothing headless. The fork also gained
   `SlippiRngSeed` / `rng_seed:` pinning the EXI device generator —
   it does NOT affect local matches (netplay-side draws only), kept
   for future online-bot work.
8. **Real hardware support** (eventually). The one remaining
   Python-libmelee parity gap: GC adapter passthrough / console
   spectate.

Standing non-goal for now: Hex/HexDocs release (revisit after the
throughput work lands).

Older still-open smalls: `Session`-based rewrite of exphil's
`MeleePort` internals; exphil peppi NIF character-id bug (Roy -> -1)
blocked on rustc/ethnum.

### Completed queue (for history)

1. ~~**Netplay Direct as a repeatable tagged test**~~ — DONE
   (`test/melee/integration/netplay_direct_test.exs`, `--only
   netplay_direct`). Passed live: A=EXPH#288 own_port=2, B=DBTD#411
   own_port=1, 23.9s.
2. ~~**Differential property test vs peppi**~~ — DONE (exphil `test/exphil/data/events_peppi_parity_test.exs`, `ExPhil.Data.Parity`): 2,625 replays / 1.34B comparisons / zero divergences.
3. ~~**Console robustness**~~ — DONE. `Melee.Console` takes an opt-in
   `reconnect:` policy (default `false` keeps the terminal
   `EnetDisconnected` behavior exphil depends on); a reconnect resets the
   `Melee.Events` parser and drops queued frames because it is a NEW
   stream. `Melee.Session` (`lib/melee/session.ex`) owns Dolphin +
   console + controllers with the startup order that took live debugging
   to find, restarts crashed controllers, and dies with Dolphin.
4. ~~**`Melee.SlpFile`**~~ — DONE (`8054bb3`): streams replays through the live codec, and manual bookends unlock pre-2.2.0 files (400/400 old replays now parse).
5. ~~**Remaining v0.47 PORT-LATER deltas**~~ — DONE. `Melee.Dolphin.Info`
   reads `~/.config/Slippi Launcher/Settings` (tolerant `useNetplayBeta`,
   ISO nulled when missing) and `prepare_home/1` falls back to it for
   `:path`/`:iso_path` — never fatally, `autodetect: false` opts out.
   `Melee.Dolphin.Version` + `Melee.Dolphin.version/1` shell out to
   `<exe> --version` and tell netplay from ExiAI on both flavors (all
   three local builds verified). Plus `:replay_monthly_folders`,
   `:log_types`/`:log_level` (Logger.ini, `"ALL"` → all 58 types, written
   only when asked for), `user.json` auto-copy with `dolphin.user_json?`,
   and a `MenuHelper.step/4` `:user_json?` flag that refuses a connect
   code without one (default `true`, so it is opt-in).
6. ~~**Rollback semantics tests**~~ — DONE (`test/melee/rollback_test.exs`): both modes, multi-frame rollback windows, the blocking-input flush obligation, and the new-game frame-clock reset.

## exphil side (for the other session)

- `ExPhil.Bridge.MeleePort` keeps its old public API
  (`init_console`/`step`/`send_controller`/`ping`/`stop`, polling and
  `:no_frame`, postgame protocol, dummy modes, frame-delay queue) and now
  drives libmelee_ex directly. Callers were unchanged.
- `ExPhil.Bridge.ActionQueue` is the ported frame-delay queue.
- `ExPhil.Replay.Stamp` + `mix exphil.stamp_replays <dir> --tag exph
  --port 1` writes `names.netplay` into `.slp` metadata so bot games are
  identifiable in a corpus (local games record no names). Verified: a
  stamped replay still parses byte-identically under peppi *and*
  libmelee_ex.
- Bot games can also carry the in-game nametag "EXPH" (see above); the
  card holding it lives at `~/.config/SlippiOnline-nametag`.
- `scripts/parity_harness.exs` and `scripts/bridge_latency_bench.exs`
  compare native vs Python. Latency: throughput is identical (~400 fps,
  emulator-bound) but the send path is ~5x cheaper natively (p50 6µs vs
  30µs).
