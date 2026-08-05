defmodule Melee do
  @moduledoc """
  libmelee_ex — an Elixir port of [libmelee](https://github.com/vladfi1/libmelee),
  the API for making Super Smash Bros. Melee AIs that work with Slippi.

  Tracks the semantics of vladfi1's actively-maintained libmelee fork.

  ## Core pieces

    * `Melee.Console` — connect to a running Slippi Dolphin instance and
      `step/1` through live `Melee.GameState` frames
    * `Melee.Controller` — press buttons and tilt sticks over Dolphin's
      named-pipe input mechanism
    * `Melee.GameState` / `Melee.PlayerState` / `Melee.Projectile` — the
      per-frame game snapshot
    * `Melee.Events` — pure decoder for Slippi's binary event stream
    * `Melee.Transport` — swappable ENet transports (Rust NIF or BEAM-native)

  Dolphin process management and menu navigation are intentionally out of
  scope for v1 — drive them from your application (see exphil for an
  example).
  """
end
