# Driving Melee's menus

Field notes for anyone extending `Melee.MenuHelper` or teaching a bot a
new screen. Everything here was measured against a real Dolphin
(netplay-stable Slippi build, NTSC 1.02) — none of it is documented by
Melee, and much of it contradicts what the code looks like it should do.

The short version: **the gamestate tells you almost nothing about
menus.** Scene ids, a menu selection index and four cursor positions is
the whole budget. There is no "the tag list is open" flag, no list
contents, no button labels. Menu code is therefore coordinate- and
frame-count-driven, and every coordinate in the library is an
empirical measurement with the evidence recorded next to it.

## The traps that cost the most time

### A controller latches its last input

`Melee.Controller` holds whatever it was last told until told otherwise.
A helper that decides "nothing to do here" and simply *returns* is not
neutral — it is still holding whatever it was holding. This bites hardest
across ports: when one port opens the name-entry keyboard, every other
port's helper hits its own idle branch, and a port that was mid-drag
keeps its stick pinned. The observable symptom is another player's hand
sailing across the screen for as long as the keyboard is up.

**Do nothing means `release_all/1`, not `return`.**

### Small stick tilts do nothing at all

`Melee.Controller.fix_analog_stick/1` compresses the `0.0..1.0` range
(1.0 becomes ~0.815), and Melee then applies its own deadzone. The
practical floor is around `0.5 ± 0.22`: anything gentler is silently
discarded, however long you hold it.

Python libmelee drags the CPU-level slider at a flat `0.15` off centre.
Once scaled, that is inside the deadzone — a drag that got within two
levels of its target would simply stop, forever. Where a slow, precise
motion is needed, use a tilt that clears the deadzone and apply it
*every other frame* instead of using a smaller one.

### The cursor accelerates

A menu cursor moves ~1.2 units on the first frame of a full tilt and
speeds up while the stick is held, so full-tilt bang-bang steering sails
straight past any target narrower than a character portrait. Ease off
within ~3 units of the target (`Melee.MenuHelper`'s `tilt/1`).

### `character` is what you are hovering; `coin_down` is not "has picked"

At the CSS, `PlayerState.character` reports whichever portrait the hand
is *over*, so it flickers between a real id and `0xFF` as the cursor
crosses the grid. It only becomes stable once the port's coin is placed —
after which it keeps reporting the pick even when the hand wanders off.

`coin_down` means "the hand is currently over this port's coin", NOT
"this port has chosen". A port that just finished dragging its CPU
slider has picked a character and `coin_down == false`. Gating readiness
on it deadlocks.

To ask "is this port locked in?", use `character` plus `cpu_level` and
`controller_status` for CPU ports (see `Melee.Probe.port_configured?/2`).
To ask "has it *just* locked in?" — the one moment where `coin_down` is
right — use both.

### Scene fields go stale

`submenu` keeps reading `18` (`name_entry_submenu`) after the name-entry
keyboard closes and the CSS is back on screen. Anything that treats
`submenu == 18` as "the keyboard is up" will strand the port: it never
picks a character, never presses START, and the match sits on READY TO
FIGHT indefinitely. This is why the nametag flow finishes on a frame
count rather than waiting for the screen to change, and why the
connect-code branch is guarded by `connect_code != nil` first.

## The character select screen

Coordinates are in Melee's cursor units, for port 1. Panels are
**15.82** apart in x, so port N is `x + 15.82 * (N - 1)`.

| Target | Coordinates | Notes |
| --- | --- | --- |
| HMN/CPU box | `(-32.2, -2.2)` | |
| CPU level slider | `(-30.9 + 15.4*(N-1), -15.12)` | note the 15.4, not 15.82 — inherited from Python |
| Name box | `(-23.7, -18.62)` | opens the tag list |
| Tag list row 2 | `y = -8.7`, any x | |
| Tag list row pitch | ~2.4 in y | |

### The name box is narrower than it looks

Presses at `x = -23.56, -23.22, -22.94` open the tag list; `-22.73` and
`-22.32` do not. The hand arrives from the character portrait on the
right, so aim left of centre and keep the tolerance tight enough to
actually pull the hand off the portrait.

### An open tag list pins the cursor's x

While the list is up, Melee holds the hand in the list's own column —
even a full tilt will not move it in x. **Only y selects a row.** Any
code that tries to steer x here will wait forever for an arrival that
cannot happen. Opening the list also *yanks* the hand off the name box,
so a press that re-checks "am I still on target" will zero its own
counter and never complete; commit to the press once it starts.

### The list is ordered: current name, saved tags…, NAME ENTRY last

NAME ENTRY is always the final row, so it *moves down* as tags are
saved. Row 2 is therefore exactly the row each mode wants — NAME ENTRY
when no tag exists yet, the saved tag once one does. That is why
create-once/select-thereafter needs a single coordinate.

Selecting any row closes the list: the tag row picks the tag, row 1
re-picks the character name, NAME ENTRY opens the keyboard. Pressing A
on the name box again toggles the list shut.

## The name-entry keyboard

The same screen `enter_direct_code/4` drives: `submenu == 18`,
`menu_selection == 45` on entry, same letter grid.

It does **not** finish the same way. START does not submit — it jumps
the selection to the CONFIRM button (`menu_selection == 57`, captioned
"Register this name."), and **A** is what registers the tag. A connect
code is submitted by START alone; a nametag needs START *then* A.

Melee nametags are at most 4 characters.

## Scenes the stream cannot name

Several screens arrive as `menu_state == 0xFF` with no players, and a
session will sit on them forever. Two show up in practice, and they want
opposite answers:

- **"Create Game Data?"** — with a card plugged in but no Melee save on
  it, at boot, Yes preselected. Dismissed with **A** (twice; an
  acknowledgement follows).
- **The Slippi log-in screen** — a Dolphin user directory that has never
  logged in boots *straight into* Online Play's log-in prompt. A does
  nothing useful; **B** backs out to a menu we understand.

`Melee.MenuHelper`'s `:unknown_scene` option tries A briefly, then falls
back to B, and never presses A once a real menu has been seen — mid
session, backing out is the only safe move.

## Coordinating two ports

A match cannot start until a second port is filled, so the usual setup is
a bot plus a CPU, one `MenuHelper` each. They never contend for input —
each writes its own controller — but they do share one decision: **when
to start the match.**

Melee raises READY TO FIGHT the instant a second port is occupied, which
is long before a CPU level has been dragged into place. An unconditional
`autostart: true` therefore starts the match at whatever level the
slider happened to be at. Gate it on the other ports being configured
(`Melee.Probe.autostart?/2`).

The gate must apply **at the CSS only**. `MenuHelper` will not navigate
the stage select at all without `autostart`, so leaving it off past the
CSS strands the run there instead.

Melee also relocates a port's hand to the top of its panel when the CSS
is interrupted — another port opening the keyboard does it — while
`is_holding_cpu_slider` can still read true. Dragging on that stale
belief walks the cursor away forever, so verify the grip (the slider
only moves the cursor in x; a cursor that has drifted in y is not on it)
and let go if it looks wrong. For the same reason a port that is *not*
being made a CPU should ignore `is_holding_cpu_slider` entirely: the CPU
state machine has no idea where the character portrait is, so nothing
walks the hand back.

## Memory cards

Nametags live in Melee's save data, so they need a card that persists.

- `Melee.Dolphin`'s `memory_card: false` (the default) unplugs both slots
  — right for a bot, which needs no save data and skips the boot prompts.
- `memory_card: true` only *preserves* whatever the config says. It does
  **not** plug a card in; a home configured with `SlotA = 255` still
  boots without one and nothing persists. This is an easy way to lose an
  hour.
- `memory_card: :folder` provisions a GCI-folder card
  (`Dolphin.gci_folder_path/2`) and selects it (`SlotA = 8`). Melee
  creates its save on first boot, via the prompt above.

## How to work out the next screen

Use `Melee.Probe` (in `test/support`, so `MIX_ENV=test`). It is the frame
loop — every operation steps the console, because Dolphin does not
advance otherwise — plus cursor steering, button pulses and tracing.
`examples/nametag_session.exs` is a worked session, including a
`diagnose` mode that logs every input to the autostart decision.

The method that worked:

1. Park at the screen with `Probe.navigate!/2`, then `goto!/4` and
   `tap!/3` by hand to find what responds.
2. Watch the actual screen. Most of these findings are invisible in the
   gamestate — the tag list being open, the hand being pinned, the CPU
   slider crawling — and were only caught by looking.
3. Record the measurement *and the counter-examples* next to the
   constant. "Opens at -23.56, -23.22, -22.94; does not at -22.73,
   -22.32" is worth far more later than a bare number.
