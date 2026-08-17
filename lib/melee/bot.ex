defmodule Melee.Bot do
  @moduledoc """
  The shortest path from "I have an idea for a bot" to it playing Melee.

  Implement one callback and hand it to `run/2`:

      defmodule HoldRight do
        use Melee.Bot

        @impl true
        def act(_me, _gamestate, controller) do
          Melee.Controller.tilt_analog(controller, :main, 1.0, 0.5)
        end
      end

      Melee.Bot.run(HoldRight,
        path: "~/.local/share/slippi/exi-ai/dolphin-emu-headless",
        iso_path: "~/isos/melee.iso",
        home: "/tmp/holdright",
        character: :fox,
        stage: :final_destination,
        opponent: [character: :falco, cpu_level: 9]
      )

  `run/2` launches a supervised `Melee.Session`, drives the menus with
  `Melee.Match` (all the coordination gates included), then calls
  `c:act/3` once per in-game frame until the game ends. The `me`
  argument is the bot's own `Melee.PlayerState` for the frame.

  Several bots can share one match — teammates in doubles, or a full
  bot free-for-all — via `run_many/2`, which fans the same frame out
  to each bot with its own controller.

  `act` is called with the controller already flushed for the frame —
  set the inputs you want and return; do not sleep, and remember the
  controller latches (not pressing is not releasing). In a Team Battle,
  `Melee.GameState.allies/2` and `enemies/2` split the field for you.
  """

  alias Melee.{GameState, Match, Session}

  @doc """
  Decide the bot's inputs for one frame.

  Called once per in-game frame with the bot's own player state, the
  full gamestate, and the bot's controller. Return `:quit` to end the
  episode with the LRAS quit-out; any other return value is ignored.
  """
  @callback act(
              me :: Melee.PlayerState.t(),
              gamestate :: GameState.t(),
              controller :: GenServer.server()
            ) :: any()

  defmacro __using__(_opts) do
    quote do
      @behaviour Melee.Bot
    end
  end

  @doc """
  Boot a session, start a match, and run the bot until the game ends.

  Options — bot side:

    * `:character` (atom or id, required), `:stage` (required)
    * `:port` — the bot's GC port, default `1`
    * `:nametag` / `:nametag_mode` — see `Melee.MenuHelper`
    * `:team` — the bot's Team Battle color (with `teams: true`)
    * `:teams` — Team Battle (see `Melee.Match` "Doubles")
    * `:opponent` — a `Melee.Match` port spec for the other panel
      (default `[character: :falco]`, an idle human dummy; add
      `cpu_level:` for a CPU)
    * `:opponent_port` — default `2`
    * `:p1`..`:p4` — explicit `Melee.Match` port specs for the other
      panels; when any are given they replace the `:opponent` sugar
    * `:match_timeout_frames` — menu budget, default `20_000`

  Everything else is passed to `Melee.Session.start_link/1` (`:path`
  and `:iso_path` at minimum; `blocking_input: true` is defaulted —
  frame-accurate bots need it, and the ExiAI build requires it for
  in-game input at all).

  Returns `{:ok, %{frames: n, last: gamestate}}` after the game ends
  (or after any bot returns `:quit`), or `{:error, reason}`.
  """
  @spec run(module(), keyword()) ::
          {:ok, %{frames: non_neg_integer(), last: GameState.t()}} | {:error, term()}
  def run(bot, opts) do
    {bot_opts, rest} = Keyword.split(opts, [:character, :port, :nametag, :nametag_mode, :team])
    port = Keyword.get(bot_opts, :port, 1)

    {sugar, rest} = Keyword.split(rest, [:opponent, :opponent_port])

    rest =
      if Enum.any?([:p1, :p2, :p3, :p4], &Keyword.has_key?(rest, &1)) do
        rest
      else
        opp_port = Keyword.get(sugar, :opponent_port, 2)
        opponent = Keyword.get(sugar, :opponent, character: :falco)
        Keyword.put(rest, :"p#{opp_port}", opponent)
      end

    run_many([{bot, Keyword.put(bot_opts, :port, port)}], rest)
  end

  @doc """
  Run SEVERAL bots in one match — doubles teammates, or a full bot
  free-for-all.

  `bots` is a list of `{module, spec}`: each spec needs `:port` and
  `:character`, plus any `Melee.Match` port-spec keys (`:team`,
  `:nametag`, ...). Non-bot panels come from `:p1`..`:p4` specs in
  `opts` (CPUs or idle humans); `opts` otherwise matches `run/2`
  (`:teams`, `:stage`, `:match_timeout_frames`, session options).

      Melee.Bot.run_many(
        [
          {FoxBot, port: 1, character: :fox, team: :red},
          {AllyBot, port: 2, character: :falco, team: :red}
        ],
        teams: true,
        p3: [character: :marth, cpu_level: 3, team: :blue],
        p4: [character: :peach, cpu_level: 3, team: :blue],
        stage: :battlefield,
        path: ..., iso_path: ..., home: ...
      )

  Each in-game frame every bot's `c:act/3` runs with its own player
  state and controller. Any bot returning `:quit` ends the episode for
  everyone.
  """
  @spec run_many([{module(), keyword()}], keyword()) ::
          {:ok, %{frames: non_neg_integer(), last: GameState.t()}} | {:error, term()}
  def run_many(bots, opts) when is_list(bots) and bots != [] do
    {match_extra, rest} = Keyword.split(opts, [:teams, :p1, :p2, :p3, :p4])
    {control, session_opts} = Keyword.split(rest, [:stage, :match_timeout_frames])

    bot_ports =
      for {_mod, spec} <- bots do
        Keyword.fetch!(spec, :port)
      end

    if Enum.uniq(bot_ports) != bot_ports do
      raise ArgumentError, "two bots share a port: #{inspect(bot_ports)}"
    end

    bot_specs =
      for {_mod, spec} <- bots do
        port = Keyword.fetch!(spec, :port)
        {:"p#{port}", Keyword.drop(spec, [:port])}
      end

    other_specs =
      for key <- [:p1, :p2, :p3, :p4], spec = Keyword.get(match_extra, key) do
        port = port_number(key)

        if port in bot_ports do
          raise ArgumentError,
                "#{key} collides with a bot's port; configure that bot in the bots list"
        end

        {key, spec}
      end

    ports =
      (bot_ports ++ Enum.map(other_specs, fn {key, _} -> port_number(key) end)) |> Enum.sort()

    session_opts =
      session_opts
      |> Keyword.put(:ports, ports)
      |> Keyword.put_new(:blocking_input, true)

    with {:ok, session} <- Session.start_link(session_opts) do
      try do
        match_opts =
          bot_specs ++
            other_specs ++
            [
              {:teams, Keyword.get(match_extra, :teams, false)},
              {:stage, Keyword.fetch!(control, :stage)},
              {:timeout_frames, Keyword.get(control, :match_timeout_frames, 20_000)}
            ]

        with {:ok, first} <- Match.play(session, match_opts) do
          runners =
            for {mod, spec} <- bots do
              port = Keyword.fetch!(spec, :port)
              {mod, port, Session.controller(session, port)}
            end

          game_loop(runners, session, first, 0)
        end
      after
        Session.stop(session)
      end
    end
  end

  defp port_number(key), do: key |> Atom.to_string() |> String.last() |> String.to_integer()

  defp game_loop(runners, session, gamestate, frames) do
    if GameState.in_game?(gamestate) do
      quit? =
        Enum.reduce(runners, false, fn {mod, port, controller}, quit? ->
          decision =
            case gamestate.players[port] do
              nil -> :cont
              me -> mod.act(me, gamestate, controller)
            end

          quit? or decision == :quit
        end)

      if quit? do
        {_mod, _port, controller} = hd(runners)

        with {:ok, last} <- Match.quit(session, controller) do
          {:ok, %{frames: frames, last: last}}
        end
      else
        case Session.step(session) do
          {:ok, next} -> game_loop(runners, session, next, frames + 1)
          nil -> game_loop(runners, session, gamestate, frames)
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:ok, %{frames: frames, last: gamestate}}
    end
  end
end
