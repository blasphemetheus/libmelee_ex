# Driving Melee's menus

Field notes for anyone extending `Melee.MenuHelper` or teaching a bot a
new screen. Everything here was measured against a real Dolphin
(netplay-stable Slippi build, NTSC 1.02) — none of it is documented by
Melee, and much of it contradicts what the code looks like it should do.

The short version: **the gamestate tells you almost nothing about
menus.** Scene ids, a menu selection index and four cursor positions is
the whole budget. There is no "the tag list is open" flag, no list
contents, no button labels. Menu code is therefore coordinate- and
frame-count-driven, and every coordinate in the library is an empirical
measurement with the evidence recorded next to it.

Read the traps first. Every one of them cost hours, and all but one look
like working code.

## What the gamestate tells you, and what lies

| Field | Trust it for | Do NOT use it for |
| --- | --- | --- |
| `menu_state` | which scene you are in | anything nameless — several screens report `0xFF` |
| `submenu` | entering the name-entry keyboard | knowing you have *left* it — it goes stale (below) |
| `menu_selection` | position on the keyboard / menu list | anything on the CSS |
| `players[n].cursor` | the hand's real position | assuming you can always move it (an open list pins x) |
| `players[n].character` | the pick, once the coin is placed | "has picked" — it reports the *hovered* portrait |
| `players[n].coin_down` | "the hand is on its coin right now" | "this port has chosen" |
| `players[n].cpu_level`, `controller_status` | CPU configuration | — |
| `is_holding_cpu_slider` | nothing on its own | it goes stale after the CSS is interrupted |
| `ready_to_start` | the READY TO FIGHT banner is up | "everything is configured" |

Nothing reports whether a tag list is open, what rows it holds, or which
button a screen is offering. That has to come from coordinates and from
looking at the screen.

## The traps that cost the most time

### A controller latches its last input

`Melee.Controller` holds whatever it was last told until told otherwise.
A helper that decides "nothing to do here" and simply *returns* is not
neutral — it is still holding whatever it was holding. This bites hardest
across ports: when one port opens the name-entry keyboard, every other
port's helper hits its own idle branch, and a port that was mid-drag
keeps its stick pinned. The observable symptom is another player's hand
sailing steadily across the screen for as long as the keyboard is up.

**Do nothing means `release_all/1`, not `return`.**

### Small stick tilts do nothing at all

`Melee.Controller.fix_analog_stick/1` compresses the `0.0..1.0` range —
`1.0` is written as `0.8153543`, `0.5` as `0.5003937` — and Melee then
applies its own deadzone. The practical floor is around `0.5 ± 0.22`:
anything gentler is silently discarded, however long you hold it.

Python libmelee drags the CPU-level slider at a flat `0.15` off centre.
Once scaled that is inside the deadzone, so a drag that got within two
levels of its target simply stopped there — the observable symptom is a
CPU level that climbs to 8 and refuses to reach 9. Where a slow, precise
motion is needed, use a tilt that clears the deadzone and apply it
**every other frame** rather than using a smaller one.

Note the asymmetry that wasted an afternoon: a gentle tilt appearing to
move the cursor vertically but not horizontally is *not* an axis-specific
deadzone. It was an open tag list pinning x (below). Test deadzone
theories on a screen you know is unconstrained.

### The cursor accelerates

A menu cursor moves ~1.2 units on the first frame of a full tilt (12
frames of full tilt covered ~14.9 units) and speeds up while the stick is
held, so full-tilt bang-bang steering sails straight past any target
narrower than a character portrait. Ease off within ~3 units of the
target — `Melee.MenuHelper`'s `tilt/1`.

### `character` is the hovered portrait; `coin_down` is not "has picked"

At the CSS, `character` reports whichever portrait the hand is *over*, so
it flickers between a real id and `0xFF` as the cursor crosses the grid.
It only becomes stable once the port's coin is placed — after which it
keeps reporting the pick even when the hand wanders off.

`coin_down` means "the hand is currently over this port's coin", NOT
"this port has chosen". A port that has just finished dragging its CPU
slider has definitely picked a character and reads `coin_down == false`,
because its hand is down at the slider. Gating readiness on it deadlocks:
the gate can never come true, and the match never starts.

So:

- **"Is this port locked in?"** — `character` matching what you asked
  for, plus `cpu_level` and `controller_status` for CPU ports. This is
  `Melee.Probe.port_configured?/2`, which deliberately ignores
  `coin_down`.
- **"Has it *just* locked in, hand still on the coin?"** — the one
  question `coin_down` answers. `MenuHelper` uses it to decide when to
  press START, which is why the helper has to walk the hand back to the
  portrait after any detour.

Because `character` flickers, a flow that starts when it first reads a
real id will be handed back control the moment the hand leaves the grid.
Latch such decisions once and do not re-derive them (`MenuHelper`'s
`:waiting` nametag phase exists for exactly this).

### `submenu` goes stale after the keyboard closes

`submenu` keeps reading `18` (`name_entry_submenu`) after the name-entry
keyboard has closed and the CSS is back on screen. Anything that treats
`submenu == 18` as "the keyboard is up" strands the port: it never picks
a character, never presses START, and the match sits on READY TO FIGHT
indefinitely while everything else looks correct.

Two consequences in this codebase:

- The nametag flow finishes on a **frame count** after pressing CONFIRM,
  because there is no screen change to wait for.
- The connect-code branch is guarded by `connect_code != nil` *before*
  `name_entry?/1`, so a stale `18` cannot capture a port that never
  wanted the keyboard.

### Stale `is_holding_cpu_slider`

Melee relocates a port's hand to the top of its panel when the CSS is
interrupted — another port opening the name-entry keyboard does it —
while `is_holding_cpu_slider` can still read true. Dragging on that stale
belief walks the cursor away across the screen forever while the level
never changes.

Two defences, both needed:

- Verify the grip. The slider only moves the cursor in **x**; a cursor
  that has drifted in y is not on it, whatever the flag says. Let go.
- A port that is not being made a CPU should ignore the flag entirely.
  Python routes on `... or is_holding_cpu_slider`, which lets a stale
  flag pull *any* port into the CPU state machine — and that machine has
  no idea where the character portrait is, so nothing ever walks the hand
  back and the match cannot be started.

### Probe steps are console steps, not emulated frames

`Melee.Probe`'s `:frames` counts how many times the probe stepped the
console. In polling mode the console hands back the *latest* gamestate,
so one step can span several of Melee's frames. A complete boot and menu
navigation is only **~230–350 steps**.

Use it for pacing (`rem(frames, 30) == 0` to log). Never use it as a
clock or as a "did this really run" guard — a guard of "more than 1000
frames" failed a run that had genuinely booted Melee, created a nametag
and written the save file. `Probe.elapsed_ms/1` is the honest measure;
the integration tests guard on wall clock, with observed runs at
8.2–11.1 s.

## The character select screen

Coordinates are in Melee's cursor units. Port 1 was measured first;
ports 2-4 were confirmed live on 2026-08-14 (netplay-stable, windowed
OGL, `Melee.Probe` sessions). The headline from that session: **two
different panel spacings coexist.** The HMN/CPU box is 15.82 apart per
port; the CPU slider *and the name box* are 15.4 apart. The name box
was originally extrapolated at 15.82, which works for ports 1-2 and
misses from port 3 on.

| Target | Coordinates | Confirmed |
| --- | --- | --- |
| HMN/CPU box | `(-32.2 + 15.82*(N-1), -2.2)` | ports 2-4 live: status toggles / full CPU config via this box |
| CPU level slider | `(-30.9 + 15.4*(N-1), -15.12)` | ports 2-4 live: dragged to level 5 |
| Name box | `(-23.7 + 15.4*(N-1), -18.62)` | all ports live; opening presses at -23.04, -8.00, 7.83, 23.20 |
| Open tag list pinned column | `-25.2 + 15.4*(N-1)` exactly | -25.2, -9.8, 5.6, 21.0 measured |
| Tag list row 2 | `y = -8.7`, x irrelevant | all ports: keyboard opened (`menu_selection == 45`) from y = -9.04 |
| Tag list row pitch | ~2.4 in y | |

### The panel is inert until a character is locked in

A port with no character picked shows an empty "N/A" panel: no HMN/CPU
tab, no name box, nothing for A to press, and `controller_status` reads
`3` (`:controller_unplugged`) even though the pad is attached and its
hand moves. Every panel interaction — name box included — requires the
port to lock a character first. `Melee.MenuHelper` encodes this
(`nametag_pending?` waits for `character_locked_in?`), but a probe
session poking coordinates directly will reproduce "the name box never
opens" perfectly until a character is picked. Cost a four-run
measurement detour; check this first.

### Detecting "the list opened" without pixels

Opening the list *yanks* the hand off the name box up into the rows
(y jumps from ~-18.4 to ~-11.5) and pins x at the list column. The
robust headless signature is the yank: after the A press, the cursor's
y sitting well above the bottom edge means the list is up. A
"full-tilt and see if x moves" probe also works, but beware two false
readings: the yank itself moves x (so measure *after* it), and at
port 4 the screen edge (x caps at 26) can fake a pin.

The pin is **one-sided**: rightward motion stops exactly at the
column, leftward motion is free (port 3's hand walked from 1.3 to
-4.0 under a left tilt with the list open). To read the column, tilt
RIGHT and take where x stops — every column (max 21.0 at port 4) sits
well left of the screen edge. `--only dolphin_css` is the rerunnable
form of these measurements.

### The name box is narrower than it looks

Presses at `x = -23.56`, `-23.22` and `-22.94` open the tag list;
`-22.73` and `-22.32` do not, at the same `y ≈ -18.5`. The hand arrives
from the character portrait on the right, so aim left of centre and keep
the tolerance tight enough to actually pull the hand off the portrait —
a tolerance wide enough to include the portrait's x means the helper
decides it has "arrived" without ever moving.

`y = -18.62` is the bottom of the cursor's travel; the hand stops there
on its own, which makes the y half of this target forgiving.

### An open tag list pins the cursor's x

While the list is up, Melee holds the hand in the list's own column. Even
a full tilt will not move it in x — this was confirmed by holding full
right for 12 frames and watching x stay at `-25.2` while y moved freely.
**Only y selects a row.** Code that tries to steer x here waits forever
for an arrival that cannot happen.

Opening the list also *yanks* the hand off the name box. A press that
re-checks "am I still on target" therefore sees itself as no longer
arrived, zeroes its own counter and never completes. Commit to a press
once it has started.

### Row order: current name, saved tags…, NAME ENTRY last

With no tags saved the list reads `Fox` / `NAME ENTRY`. After saving one
it reads `Fox` / `EXPH` / `NAME ENTRY` — **NAME ENTRY is always last and
moves down as tags accumulate.**

Measured, with x anywhere from `-29.5` to `-25.2`:

- Zero saved tags: A hit NAME ENTRY at `y = -9.66, -9.04, -8.58, -7.78`.
  `y = -11.5` hit nothing.
- One saved tag: NAME ENTRY had moved to `y ≈ -11.1`.

That difference gives the ~2.4 row pitch, and it means **row 2 is
exactly the row each mode wants** — NAME ENTRY when no tag exists yet,
the saved tag once one does. A single coordinate serves both, which is
what makes create-once / select-thereafter workable.

Selecting any row closes the list: the tag row picks the tag, row 1
re-picks the character name, NAME ENTRY opens the keyboard. Pressing A on
the name box again toggles the list shut, which is a usable "start over"
if a press seems to have missed.

## The name-entry keyboard

The same screen `enter_direct_code/4` drives: `submenu == 18`,
`menu_selection == 45` on entry, the same letter grid.

It does **not** finish the same way. START does not submit — it jumps the
selection to the CONFIRM button (`menu_selection == 57`, captioned
"Register this name.") and **A** is what registers the tag. A Slippi
connect code is submitted by START alone; a nametag needs START *then*
A. Getting this wrong looks like the keyboard simply ignoring you.

Melee nametags are at most 4 characters. After CONFIRM, see the stale
`submenu` trap above — there is no screen change to wait on.

## Scenes the stream cannot name

Several screens arrive as `menu_state == 0xFF` with no players, and a
session will sit on them forever because no navigation code claims them.
Two show up in practice, and they want opposite answers:

- **"Create Game Data?"** — with a card plugged in but no Melee save on
  it, at boot, Yes preselected. Dismissed with **A**, twice: an
  acknowledgement follows.
- **The Slippi log-in screen** — a Dolphin user directory that has never
  logged in to Slippi boots *straight into* Online Play's log-in prompt.
  A does nothing useful there; **B** backs out to a menu we understand.

`Melee.MenuHelper`'s `:unknown_scene` option tries A briefly, then falls
back to B, and never presses A once a real menu has been seen — mid
session, backing out is the only safe move. Note that A-mashing a
nameless scene is how a run ends up deep in Online Play in the first
place, so keep the budget short.

## Memory cards

Nametags live in Melee's save data, so they need a card that persists.

- `memory_card: false` (the default) unplugs both slots. Right for a
  bot: no save data needed, and the boot prompts never appear.
- `memory_card: true` only *preserves* whatever the config already says.
  It does **not** plug a card in. A home whose `Dolphin.ini` has
  `SlotA = 255` still boots without one, and everything the game "saves"
  is gone at exit. A nametag created this way survives the session and
  vanishes on restart, which looks exactly like a broken nametag flow.
- `memory_card: :folder` provisions a GCI-folder card
  (`Dolphin.gci_folder_path/2`, `<home>/GC/<region>/Card A`) and selects
  it with `SlotA = 8`. Melee creates its save there on first boot via the
  prompt above. This is the option you want for nametags.

## Coordinating two ports

A match cannot start until a second port is filled, so the usual setup is
a bot plus a CPU, one `MenuHelper` each. They never contend for input —
each writes its own controller — but they share one decision: **when to
start the match.**

Melee raises READY TO FIGHT the instant a second port is occupied, which
is long before a CPU level has been dragged into place. An unconditional
`autostart: true` therefore starts the match at whatever level the slider
happened to be at. Gate it on the other ports being configured:
`Melee.Probe.autostart?/2`.

The gate must apply **at the CSS only**. `MenuHelper` will not navigate
the stage select at all without `autostart`, so a gate that stays false
past the CSS strands the run there instead — trading a stall on one
screen for a stall on the next.

### Sequence cross-port flows; never interleave them

The nametag flow (tag list, name-entry keyboard) *interrupts the CSS*,
and Melee responds by relocating **every other port's hand** to the top
of its panel. A port mid-CPU-slider-drag gets yanked off one level
short — observed live as "asked for 9, stuck at 8": the drag is
interrupted, the re-grab at the fixed slider coordinate misses the
handle (it has moved with the level), and the autostart gate then
correctly never opens, so the run sits on the CSS forever.

So when one port needs a nametag and another needs CPU config, run
them in sequence: withhold the `:nametag` option until the CPU port is
`port_configured?/2`, then let the nametag flow run — its interruption
is harmless once the level is already set. The nametag integration
test is the worked example.

## How to work out a new screen

The gamestate will not tell you. The method that worked was to drive the
game by hand with a rendered window open and *look at it*.

### Drive it

`Melee.Probe` (in `test/support`, so `MIX_ENV=test`) is the frame loop —
every operation steps the console, because **Dolphin does not advance
unless the console is stepped**, so a tilt that is set but never stepped
does nothing at all. On top of that it gives cursor steering (`goto!/4`),
button pulses (`tap!/3`), waiting (`until!/4`) and tracing.

`examples/nametag_session.exs` is a worked session with a `diagnose` mode
that logs every input to the autostart decision each half-second. When a
run stalls, that one line tells you which gate is false; guessing from a
screenshot does not.

Launch with `headless: false` and a real `gfx_backend` — you need pixels.

### Look at it

Under Hyprland, capture the Dolphin window:

```sh
geo=$(hyprctl clients | grep -A22 "initialTitle: Dolphin" -B22 \
        | grep -E "^\s+(at|size):" | head -2)
at=$(echo "$geo"   | grep at:   | awk '{print $2}')   # e.g. 971,575
size=$(echo "$geo" | grep size: | awk '{print $2}')   # e.g. 916,472
grim -g "$at ${size/,/x}" shot.png
magick shot.png -resize 900x big.png                  # then read big.png
```

Match on `initialTitle: Dolphin`, not the window title: Slippi rewrites
the title at runtime (it reports things like "Wrote save contents to …"),
so a title match breaks mid-session.

Nearly every finding here was invisible in the gamestate and caught by
looking: the tag list being open, the hand pinned in the list's column,
the CPU slider stuck at 8, the log-in screen, the nameplate reading
`EXPH`. Take a screenshot before forming a theory.

### Park and poke

1. Get to the screen with `Probe.navigate!/2`.
2. `goto!/4` to a coordinate, `tap!/3` a button, screenshot, and see what
   changed — in the picture *and* in the gamestate.
3. Bisect the boundaries. A single working coordinate is not a target;
   find where it stops working on each side.
4. Record the measurement **and the counter-examples** next to the
   constant. "Opens at -23.56, -23.22, -22.94; does not at -22.73,
   -22.32" is worth far more six months later than a bare number, because
   the next person will need to know whether a near miss is in range.

### Verify honestly

Assert on things that cannot be true by accident: the tag actually
present in a `GAME_START` event, a `.gci` written to a card folder that
was wiped at the start of the test, the CPU level reading 9. Then add a
wall-clock floor so a vacuous pass is caught — and remember that step
counts are not frames.
