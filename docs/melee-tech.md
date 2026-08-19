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

## Tier 1 — implemented, live-verified (`--only dolphin_movement`)

| Tech | Routine | Live proof |
| --- | --- | --- |
| Short hop | `:short_hop` | apex 3.97 vs full hop's 7.13 (Fox) |
| Full hop | `:full_hop` | ditto |
| Wavedash | `:wavedash` | 8/8 special landings, 21.1 units of travel each — byte-repeatable |
| Dash dance | `:dash_dance` | 15 flips/120 frames, drift-banded around its origin |
| L-cancel (via SHFFL) | `:shffl` | nair landing lag 6 frames vs 14 in the identical no-L control run |
| SHFFL | `:shffl` | the above, with fast fall confirmed by the lag window even existing |
| Multishine | `:multishine` | 37 shines/300 frames — the historical 8-frame cycle |

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

## Tier 2 — next: universal, buildable with current readbacks

- **Waveland** — the wavedash airdodge from an airborne approach onto
  a platform; same input core, platform-height awareness.
- **Fast fall** as a standalone routine (currently inside `:shffl`).
- **Teching** (in place / roll) — press L within 20 frames before
  hitting the ground in tumble; reactive off `hitstun_frames_left` +
  projected landing.
- **Pivot / empty pivot** — 1-frame turnaround out of dash.
- **Ledgedash** — ledge release, double jump in, airdodge onto stage
  with invincibility frames; needs ledge action-state handling
  (`Melee.FrameData` has the roll/ledge data).
- **Jump-cancel grab / shine grab**; **wavedash out of shield**.
- **Powershield** — 2-frame window; feasible against seen
  projectiles via `Projectile` tracking.
- **Moonwalk**, **fox trot**, **crouch cancel**, **shield drop**
  (axis-notch emulation is trivial for a virtual controller).

## Tier 3 — character-specific

- **Fox/Falco**: waveshine (+ shine turnaround), short-hop
  laser/double laser, drillshine, thunders. `:multishine` already
  handles both via the jumpsquat table.
- **Peach**: float cancel aerials.
- **Ness / Mewtwo / Yoshi / Peach**: double-jump cancel (DJC) aerials.
- **Samus**: missile cancel, bomb jump, extended grapple.
- **Ice Climbers**: desyncs (Nana is already visible as
  `player.nana`), handoffs.
- **Marth**: pivot tipper spacing (pairs with `FrameData.in_range/3`).
- **Yoshi**: parry (shield on frame 1 of... unique double-jump armor).
- **Falcon/Ganon**: gentleman, instant reverse aerials.

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
