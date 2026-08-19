# Melee tech: the catalog and what Melee.Tech covers

`Melee.Tech` implements frame-perfect tech-skill primitives as pure,
per-frame state machines (see the module docs for the API). Melee's
tech vocabulary is large and partly character-specific; this page is
the map — what exists in the game, what the library implements, and
what each remaining item would need. Compiled from the community
references (SmashWiki's [Advanced technique](https://www.ssbwiki.com/Advanced_technique),
[Wavedash](https://www.ssbwiki.com/Wavedash),
[L-canceling](https://www.ssbwiki.com/L-canceling) and the
[Wikibooks Melee techniques guide](https://en.wikibooks.org/wiki/Super_Smash_Bros._Melee/Techniques/Advanced)).

## Implemented, live-verified (`--only dolphin_movement`)

| Tech | Routine | Live proof |
| --- | --- | --- |
| Short hop | `:short_hop` | apex 3.97 vs full hop's 7.13 (Fox) |
| Full hop | `:full_hop` | ditto |
| Wavedash | `:wavedash` | 8/8 special landings, 21.1 units of travel each — byte-repeatable |
| Dash dance | `:dash_dance` | 15 flips/120 frames, drift-banded around its origin |
| L-cancel (via SHFFL) | `:shffl` | nair landing lag 6 frames vs 14 in the identical no-L control run |
| SHFFL | `:shffl` | the above, with fast fall confirmed by the lag window even existing |
| Multishine | `:multishine` | 37 shines/300 frames — the historical 8-frame cycle |
| Fast fall | `:fast_fall` | (inside `:shffl`'s lag proof; standalone routine) |
| Waveland | `:waveland` | airdodge-landing (`landing_special`) from a full hop |
| Empty pivot | `:pivot` | facing flips, ends standing within ~12 units (a run-stop takes ~40) |
| Ground tech | `:tech` | 0xC7 tech-in-place on the fall from a scripted 58% launch (`--only dolphin_defense`) |
| Ledgedash | `:ledgedash` | grab -> DJ above the lip -> dodge in -> `landing_special` ON STAGE with ledge invincibility intact (galint) |
| Waveshine | `:waveshine` | 4/4 shines jump-cancelled into 4/4 wavedashes out |
| Short-hop laser | `:short_hop_laser` | the laser projectile observed mid-air (`ProjectileType` 0x36) |
| DJC aerial | `:djc_aerial` | Ness DJC nair at apex 2.91 — a fraction of his jump height; Mewtwo at 2.72 (`--only dolphin_mewtwo`) |
| DI | `:di` | vs a control launch off falco's up-smash: knockback dx −9.2 vs 0.5 over 20 frames (`--only dolphin_defense`) |
| SDI | `:sdi` | 22.7 units of slide during a 7-frame hitlag vs 0.0 in the control run |
| ASDI down | `:asdi_down` | unit-pinned (c-stick parked through hitlag); composes with `:tech` for the Amsah tech |
| Shadow ball store | `:shadow_ball_charge` | charge loop observed, shield-cancel lands in SpecialNCancel (0x158) with the charge stored |
| Shadow ball fire | `:shadow_ball_fire` | release state (0x159) reached and the projectile observed in `gs.projectiles` |
| Teledgehog | `:teledgehog` | ends hanging: CliffCatch (0xFC) at (90.5, −10.9) off FD's right lip |
| JC grab | `:jc_grab` | Catch (0xD4, the STANDING grab) out of a dash, via Z in jumpsquat (`--only dolphin_universal`) |
| Shine grab | `:shine_grab` | shine -> jump-cancel -> Z: shine, knee_bend, Catch all in one chain |
| Instant RAR | `:instant_rar` | bair with facing flipped and 38.7 units of run-direction drift (`--only dolphin_characters`) |
| Yoshi egg shield | (`:powershield` inputs) | egg states 0x156/0x159 mapped; laser crosses with zero damage/stun |
| Moonwalk | `:moonwalk` | dash-end speed 0.19 u/f vs 2.2 in the stick-held control — the down-back park kills the dash velocity with no turn |
| Fox trot | `:fox_trot` | 3 initial-dash starts, run (0x15) never entered |
| Crouch cancel | `:crouch_cancel` | launch peak 0.0 (never left the ground) vs 9.59 control, at HIGHER percent |
| Wavedash OOS | `:wavedash_oos` | shield (R) -> jump-cancel -> L-airdodge special landing |
| Powershield | `:powershield` | GuardReflect (0xB6) on a tracked falco laser, press timed by frames-to-impact |
| Shield drop | `:shield_drop` | Pass (0xF4) through a Battlefield side platform from shield |
| Drillshine | `:drillshine` | dair -> L-cancelled landing -> shine 9 frames later |
| Double laser | `:double_laser` | 2 lasers spawned in one falco short hop |
| Shine turnaround | `:shine_turnaround` | facing flips into 0x16C (shine-turn) without leaving the shine family |

The composability check that closed the loop: the ledgedash test's
ledge GRAB is itself built from the primitives — walk to the edge,
`:pivot` to face the stage, backward `:wavedash` off — and the
airdodge freefall grabs the ledge.

Hard-won geometry facts (each cost a dead Fox):

- A ledgedash airdodge from BELOW the ledge dives to a death; from
  BESIDE the stage it hits the wall and slides down it. The dodge
  must wait for the double jump to rise ABOVE the lip
  (`dodge_height`, default +1.0).
- `:tech` must never pulse L — an early press is a 40-frame lockout.
  It arms once, close to the ground, from tumble/damage-fall states.
  Its arming check must read `speed_y_self + speed_y_attack` — during
  knockback the downward velocity lives ENTIRELY in the attack
  component, and a self-speed-only check never fires.
- Mewtwo's shadow ball state map (learned by trace, one wrong guess at
  a time): 0x155 start, 0x156 charge loop, 0x157 FULL-charge hold loop
  (it does NOT auto-exit — release_all leaves him parked there
  forever), 0x158 shield-cancel/store, 0x159 release. Pressing B with
  a stored charge RESUMES the charge; firing takes a second B edge.
- Teledgehog geometry: FD's lip is x = ±85.57 (not Battlefield's
  68.4 — a run of overshoots taught us which stage we were on), the
  teleport travels a FIXED ~38–43 units and hugs the ground, and a
  fall only grabs a ledge it FACES. The routine therefore turns away
  from the ledge first (the teleport's direction is stick-controlled,
  facing-independent), hops out past the lip with backward drift, and
  holds stage-ward through the sink — the lip-hugging fall catches the
  ledge (CliffCatch 0xFC, a wide box: caught at 5 units out) before
  the teleport is even needed; the up-aimed teleport stays as the
  deep-miss fallback. Watch for 0xFC as well as 0xFD: pressing B on
  the catch frame teleports OFF the freshly caught ledge.

Key implementation facts, all live-measured:

- **Jumpsquat is the per-character timing anchor** (Fox 3, Falco 5,
  Bowser 8...); the module carries the full NTSC table. libmelee's
  `characterdata.csv` does not include it.
- **The wavedash airdodge is input on the first airborne frame** —
  under blocking input every frame is observed exactly once, so
  "first frame with `on_ground == false`" is a precise trigger, no
  jumpsquat counting needed.
- **The L-cancel needs a press EDGE within 7 frames of landing.**
  Rather than predicting the landing frame, `:shffl` pulses L on a
  6-frame period through the falling aerial: some edge always falls
  inside any 7-frame window, and extra pulses have no effect in an
  aerial attack.
- **Open-loop dash dancing drifts** — an uncorrected interval-8 dance
  walked Fox off FD's edge within ~200 frames. The routine is
  closed-loop around its starting position.

## Dash-state lessons (the universal batch's dead ends)

- **An initial dash's animation completes regardless of the stick.**
  Re-smashing forward mid-dash feeds a forward-hold into the RUN; a
  fox trot must go neutral and re-smash only after the dash action
  ends (fox's dash runs 21 frames at neutral).
- **The moonwalk park dodges two cancels**: |x| >= 0.8 back is a
  smash-turn, deep down is a crouch. At (~-0.76, -0.5), rolled in on
  dash frame 2, the velocity dies to ~0 by dash end (vs 2.2 u/f in
  the control) — fox can't NET-reverse a standing start in one dash,
  so the proof is the A/B deceleration, not backward displacement.
- **Smash inputs need neutral first**: starting a dash out of a walk
  just walks faster. Settle to STANDING (0x0E) — walks 0x0F..0x11
  also sit below 0x40 and poison "actionable" checks.
- **A dash attack sails over a crouched fox** — the crouch-cancel
  launcher is falco's dtilt.
- Positioning walks flip the walker's FACING; a falco meant to laser
  or dtilt leftward needs a leftward step before settling.

## Research findings (`--only dolphin_research`)

Four of the open questions got answers:

| Question | Verdict | Evidence |
| --- | --- | --- |
| Mewtwo teleport cancel | REAL, proven | grounded teleport travels 55.2 units with a 29-frame end animation (0x163); ending it ~1.5 units inside FD's lip slides the end animation off the edge — and mewtwo can DOUBLE JUMP out of the fall (special fall can't jump; the exit is fully actionable) |
| Marth tipper | proven, FrameData-spaced | `FrameData.range_forward(marth, fsmash, 1)` = 32.0; spacing falco at range+3 (his body width offsets the contact inward) hits for 18.2 vs 14.0 point-blank |
| Thunders combo | proven, through GameEvents | `:uthrow_uair` connects at ~40%+ (the ThrowUp animation runs ~26 frames while a low-percent pop peaks at 31 and falls back — measured); the landed combo registers as ONE conversion: 18.7 damage, 5 moves |
| Peach 40% float cancel | did NOT reproduce | full matrix measured: attack INSIDE float lands heavy (~29f, any height/release timing); attack AFTER releasing float lands at exactly NORMAL lag (14 = control); Slippi's l_cancel byte never fires (0) in any variant. Either the folklore mechanics differ from all these input shapes, or the FC needs something EXI-driven inputs aren't producing — left open, with the matrix as the map |

Thunders timing facts: the up-throw needs a stick edge IN CatchWait
(0xD8) — an up-tilt held from CatchPull never throws; and the uair
must ride the jump (a first-airborne-frame swing passes under the
victim).

## Remaining backlog

Samus's platform EDGE-cancelled missile, bomb jump, and extended
grapple; ICs handoffs (the grab desync is done); Yoshi's parry
intangibility pin (egg-shield behavior mapped above); Peach's 40% FC
mechanism (matrix above).

## Tier 4 — hit response

The PRIMITIVES landed in this module: `:di`, `:sdi`, `:asdi_down`,
plus the live `:tech` proof, all measured A/B against control runs
under a scripted falco up-smash launcher
(`test/melee/integration/defense_test.exs`, `--only dolphin_defense`).
The vertical launch makes both measurements percent-robust: SDI is
displacement DURING hitlag (the control is frozen), DI is the
horizontal drift of the post-hitlag knockback path (the control flies
straight up).

What remains policy rather than primitive — DI *mixups*, tech chases,
edgeguard decision trees — belongs on top of `Melee.GameEvents`, not
in this module.

## Character kits

Mewtwo (`--only dolphin_mewtwo`): DJC nair (`:djc_aerial` — his
double jump is a slow roll and still cancels), `:shadow_ball_charge` /
`:shadow_ball_fire` (shield-stored charge, two-B-edge release),
`:teledgehog`. Backlog: teleport-cancel (near-ground endlag cancel).

The kit batch (`--only dolphin_characters`, one boot each):

| Tech | Routine | Live proof |
| --- | --- | --- |
| Peach float + float-aerial | `:float_cancel` | float (0x155) armed by an apex down-tap with jump held; float-nair is its OWN action family (0x158..0x15C) |
| Falcon gentleman | `:gentleman` | jab3 (0x2E) reached, rapid jab (0x2F) never — the links must be SLOW |
| Marth pivot fsmash | `:pivot_smash` | facing flips and the c-stick fsmash lands on the turn |
| Samus SH missile | `:sh_missile` | missile spawns; landing pinned at the 30-frame heavy landing |
| ICs grab desync | `:ics_desync` | Popo holds CatchWait (0xD8) while Nana blizzards (0x155) |

Hard-won facts from this batch:

- **Landing inside ANY special animation is a ~30-frame heavy
  landing** — measured for Samus's missile (every fire height, SH and
  FH) and Peach's float-nair (every float height and release timing).
  Melee's community "missile cancel" is a platform EDGE-cancel
  (backlog); Peach's folkloric 40% float cancel did not reproduce
  under any input we tried (refinement backlog) — her float and
  float-aerials themselves are fully drivable.
- **Peach's float arms from a down-tap near the apex with jump
  held**; at ground level the down+jump ground-float works too, but
  the drop lands the frame the release registers. Float aerials use
  their own action ids (0x158..0x15C), not 0x41..0x45.
- **Nana echoes the grab 6 frames late and whiffs** — the desync's B
  press must wait for HER catch endlag to finish (`player.nana` is in
  the state feed), or she eats the input in lag and stays synced.
- **The gentleman is a patience test**: press A only after each jab
  reaches frame 3+; mashing buffers the rapid jab (0x2F).
- **Yoshi's shield is not a shield**: the egg lives in the SPECIAL
  action range (0x156 hold, 0x159 release — not 178..180), it never
  GuardReflects, and the `invulnerable` flag stays false through it.
  A falco laser crosses a shielding yoshi with zero damage and zero
  stun (parry-consistent); pinning the parry's intangible startup
  frames specifically needs hitbox-level data (backlog).

Batch 3 (in the same suites): `:shine_grab` (shine -> jump-cancel ->
Z in jumpsquat: shine, knee_bend, and Catch 0xD4 all observed — the
shined target slides out of range, so the catch whiffs by design),
`:instant_rar` (run, turnaround jump, bair mid-drift: bair lands with
the facing flipped and 38.7 units of run-direction drift).

## Verification convention

Every routine lands with an assertion that cannot pass vacuously
(apex ratios, landing-action counts, an A/B lag comparison against a
control run, cycle-rate floors) in
`test/melee/integration/tech_movement_test.exs`,
`test/melee/integration/defense_test.exs` (a scripted port-2 falco
launcher for the hit-response tier), and
`test/melee/integration/mewtwo_tech_test.exs`, plus pure unit tests
over the step machines in `test/melee/tech_test.exs`. The launcher
tests boot with `boot_rules: [stock: 99, time_limit: 99]` — Melee's
factory default is a 2-MINUTE TIMED match, which an FFW run blows
through mid-test.
