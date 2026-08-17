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

  `act` is called with the controller already flushed for the frame —
  set the inputs you want and return; do not sleep, and remember the
  controller latches (not pressing is not releasing).
  """

  alias Melee.{GameState, Match, Session}

  @doc """
  Decide the bot's inputs for one frame.

  Called once per in-game frame with the bot's own player state, the
  full gamestate, and the bot's controller.
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
    * `:opponent` — a `Melee.Match` port spec for the other panel
      (default `[character: :falco]`, an idle human dummy; add
      `cpu_level:` for a CPU)
    * `:opponent_port` — default `2`
    * `:match_timeout_frames` — menu budget, default `20_000`

  ## Doubles

  Pass `teams: true`, the bot's own `:team`, and explicit `p2:`/`p3:`/
  `p4:` port specs (which replace the `:opponent` sugar):

      Melee.Bot.run(MyBot,
        teams: true,
        character: :fox,
        team: :red,
        p2: [character: :falco, cpu_level: 3, team: :red],
        p3: [character: :marth, cpu_level: 3, team: :blue],
        p4: [character: :peach, cpu_level: 3, team: :blue],
        stage: :battlefield,
        path: ..., iso_path: ..., home: ...
      )

  The bot still controls exactly one port; teammates and opponents are
  CPUs or idle humans. See `Melee.Match` "Doubles" for the mechanics
  and the fresh-session caveat.

  ## Ending an episode early

  `c:act/3` may return `:quit`: the game is ended with the LRAS
  quit-out (`Melee.Match.quit/3` — note the pre-GO pause lockout means
  a quit in the first ~2s of a match lands at frame 0). Any other
  return value is ignored.

  Everything else is passed to `Melee.Session.start_link/1` (`:path`
  and `:iso_path` at minimum; `blocking_input: true` is defaulted —
  frame-accurate bots need it, and the ExiAI build requires it for
  in-game input at all).

  Returns `{:ok, %{frames: n, last: gamestate}}` after the game ends,
  or `{:error, reason}`.
  """
  @spec run(module(), keyword()) ::
          {:ok, %{frames: non_neg_integer(), last: GameState.t()}} | {:error, term()}
  def run(bot, opts) do
    {bot_opts, session_opts} =
      Keyword.split(opts, [
        :character,
        :stage,
        :port,
        :nametag,
        :nametag_mode,
        :team,
        :teams,
        :opponent,
        :opponent_port,
        :p1,
        :p2,
        :p3,
        :p4,
        :match_timeout_frames
      ])

    port = Keyword.get(bot_opts, :port, 1)
    port_specs = port_specs(bot_opts, port)
    ports = port_specs |> Enum.map(fn {key, _} -> port_number(key) end) |> Enum.sort()

    session_opts =
      session_opts
      |> Keyword.put(:ports, ports)
      |> Keyword.put_new(:blocking_input, true)

    with {:ok, session} <- Session.start_link(session_opts) do
      try do
        match_opts =
          port_specs ++
            [
              {:teams, Keyword.get(bot_opts, :teams, false)},
              {:stage, Keyword.fetch!(bot_opts, :stage)},
              {:timeout_frames, Keyword.get(bot_opts, :match_timeout_frames, 20_000)}
            ]

        with {:ok, first} <- Match.play(session, match_opts) do
          controller = Session.controller(session, port)
          game_loop(bot, session, port, controller, first, 0)
        end
      after
        Session.stop(session)
      end
    end
  end

  # The bot's own spec first (it is the Match leader), then explicit
  # p1..p4 specs, then — only when no explicit specs were given — the
  # 1v1 :opponent sugar.
  defp port_specs(bot_opts, port) do
    bot_key = :"p#{port}"
    bot_spec = Keyword.take(bot_opts, [:character, :nametag, :nametag_mode, :team])

    explicit =
      for key <- [:p1, :p2, :p3, :p4], spec = Keyword.get(bot_opts, key) do
        if key == bot_key do
          raise ArgumentError,
                "#{key} collides with the bot's own port; configure the bot via " <>
                  ":character/:team, not a port spec"
        end

        {key, spec}
      end

    others =
      if explicit == [] do
        opp_port = Keyword.get(bot_opts, :opponent_port, 2)
        [{:"p#{opp_port}", Keyword.get(bot_opts, :opponent, character: :falco)}]
      else
        explicit
      end

    [{bot_key, bot_spec} | others]
  end

  defp port_number(key), do: key |> Atom.to_string() |> String.last() |> String.to_integer()

  defp game_loop(bot, session, port, controller, gamestate, frames) do
    if GameState.in_game?(gamestate) do
      decision =
        case gamestate.players[port] do
          nil -> :cont
          me -> bot.act(me, gamestate, controller)
        end

      case decision do
        :quit ->
          with {:ok, last} <- Match.quit(session, controller) do
            {:ok, %{frames: frames, last: last}}
          end

        _ ->
          case Session.step(session) do
            {:ok, next} -> game_loop(bot, session, port, controller, next, frames + 1)
            nil -> game_loop(bot, session, port, controller, gamestate, frames)
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:ok, %{frames: frames, last: gamestate}}
    end
  end
end
