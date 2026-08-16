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
        :opponent,
        :opponent_port,
        :match_timeout_frames
      ])

    port = Keyword.get(bot_opts, :port, 1)
    opp_port = Keyword.get(bot_opts, :opponent_port, 2)
    opponent = Keyword.get(bot_opts, :opponent, character: :falco)

    session_opts =
      session_opts
      |> Keyword.put(:ports, [port, opp_port])
      |> Keyword.put_new(:blocking_input, true)

    with {:ok, session} <- Session.start_link(session_opts) do
      try do
        match_opts =
          [
            {:"p#{port}", Keyword.take(bot_opts, [:character, :nametag, :nametag_mode])},
            {:"p#{opp_port}", opponent},
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

  defp game_loop(bot, session, port, controller, gamestate, frames) do
    if GameState.in_game?(gamestate) do
      if me = gamestate.players[port], do: bot.act(me, gamestate, controller)

      case Session.step(session) do
        {:ok, next} -> game_loop(bot, session, port, controller, next, frames + 1)
        nil -> game_loop(bot, session, port, controller, gamestate, frames)
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %{frames: frames, last: gamestate}}
    end
  end
end
