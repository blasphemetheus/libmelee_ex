defmodule Melee.Integration.BotApiTest do
  use ExUnit.Case

  @moduledoc """
  The high-level API, end to end: `Melee.Bot.run/2` (which wraps
  `Melee.Session` + `Melee.Match`) boots Dolphin, coordinates the
  menus, plays a whole game with a one-callback bot, and returns when
  Melee says the game is over. No Probe, no MenuHelper plumbing — only
  the public API a new user would touch.

  The bot holds right, so Fox dashes off the right edge and burns all
  four stocks; the game ends on its own.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_match
  """

  alias Melee.GameState

  @moduletag :dolphin
  @moduletag :dolphin_match
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_bot_api_it")

  defmodule LemmingBot do
    use Melee.Bot

    @impl true
    def act(_me, _gamestate, controller) do
      Melee.Controller.tilt_analog(controller, :main, 1.0, 0.5)
    end
  end

  setup_all do
    path = System.get_env("MELEE_DOLPHIN_PATH")
    iso = System.get_env("MELEE_ISO_PATH")

    if path == nil or iso == nil do
      {:ok, skip: "set MELEE_DOLPHIN_PATH and MELEE_ISO_PATH"}
    else
      File.rm_rf!(@home)
      {:ok, path: Path.expand(path), iso: Path.expand(iso)}
    end
  end

  test "Bot.run plays a full game through the public API", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"
      started = System.monotonic_time(:millisecond)

      result =
        Melee.Bot.run(LemmingBot,
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_595,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          console: [polling_mode: true, polling_timeout: 100],
          character: :fox,
          stage: :final_destination,
          opponent: [character: :falco]
        )

      elapsed = System.monotonic_time(:millisecond) - started

      assert {:ok, %{frames: frames, last: last}} = result

      # Four self-destruct cycles measure ~250 frames each (dash off,
      # fall, respawn, repeat) — the observed game is 1003 frames.
      # Anything much shorter never really played, and the loop must
      # have ended because Melee said so.
      assert frames > 800, "game over after only #{frames} frames"
      refute GameState.in_game?(last)

      IO.puts("\n[dolphin] bot_api: #{elapsed}ms frames=#{frames}")
    end
  end
end
