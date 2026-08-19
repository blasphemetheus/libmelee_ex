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
| Ground tech | `:tech` | unit-verified single-press arming (a live proof needs a scripted hit — see below) |
| Ledgedash | `:ledgedash` | grab -> DJ above the lip -> dodge in -> `landing_special` ON STAGE with ledge invincibility intact (galint) |
| Waveshine | `:waveshine` | 4/4 shines jump-cancelled into 4/4 wavedashes out |
| Short-hop laser | `:short_hop_laser` | the laser projectile observed mid-air (`ProjectileType` 0x36) |
| DJC aerial | `:djc_aerial` | Ness DJC nair at apex 2.91 — a fraction of his jump height |

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
  A live proof needs an opponent scripted to launch the subject
  (future work; the state machine is unit-pinned).

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

## Remaining backlog

Universal: jump-cancel grab / shine grab; wavedash out of shield;
powershield (2-frame window, feasible against seen projectiles);
moonwalk, fox trot, crouch cancel, shield drop (axis-notch emulation
is trivial for a virtual controller); a LIVE proof for `:tech` (needs
an opponent scripted to launch the subject).

Character-specific: Fox/Falco drillshine, double laser, thunders,
shine turnaround; Peach float-cancel aerials; Samus missile cancel /
bomb jump / extended grapple; Ice Climbers desyncs (Nana is already
visible as `player.nana`) and handoffs; Marth pivot-tipper spacing
(pairs with `FrameData.in_range/3`); Yoshi parry; Falcon/Ganon
gentleman and instant reverse aerials.

## Tier 4 — reactive defense (needs opponent modeling)

SDI/ASDI patterns, Amsah tech, DI mixups, tech chases,
edgeguard/ledge-hog decision trees. These are policies more than
primitives — the natural place for them is on top of `Melee.GameEvents`
(roadmap item 4) rather than in this module.

## Verification convention

Every routine lands with an assertion that cannot pass vacuously
(apex ratios, landing-action counts, an A/B lag comparison against a
control run, cycle-rate floors) in
`test/melee/integration/tech_movement_test.exs`, plus pure unit tests
over the step machines in `test/melee/tech_test.exs`.
