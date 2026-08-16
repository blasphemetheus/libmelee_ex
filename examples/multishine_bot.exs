# A frame-perfect multishine bot, whole thing.
#
#   MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \
#   MELEE_ISO_PATH=~/isos/melee.iso \
#   mix run examples/multishine_bot.exs
#
# Boots Dolphin headless, coordinates the menus, and Fox multishines at
# the theoretical 8-frame cycle until the game ends (Ctrl-C when
# satisfied, or pass MELEE_WINDOWED=1 to watch it).

defmodule MultishineBot do
  use Melee.Bot

  alias Melee.{Controller, Enums}

  @standing Enums.Action.to_id(:standing)
  @knee_bend Enums.Action.to_id(:knee_bend)
  @shine_start Enums.Action.to_id(:down_b_ground_start)
  @shine Enums.Action.to_id(:down_b_ground)
  @shine_stun Enums.Action.to_id(:down_b_stun)

  @impl true
  def act(me, _gamestate, controller) do
    cond do
      me.action == @standing ->
        Controller.press_button(controller, :b)
        Controller.tilt_analog(controller, :main, 0.5, 0.0)

      me.action == @knee_bend and me.action_frame == 3 ->
        Controller.press_button(controller, :b)
        Controller.tilt_analog(controller, :main, 0.5, 0.0)

      me.action == @knee_bend ->
        Controller.release_button(controller, :b)

      me.action in [@shine_start, @shine_stun] and me.action_frame >= 3 and me.on_ground ->
        Controller.release_button(controller, :b)
        Controller.press_button(controller, :y)

      me.action == @shine ->
        Controller.press_button(controller, :y)

      true ->
        Controller.release_all(controller)
    end
  end
end

windowed? = System.get_env("MELEE_WINDOWED") == "1"

{:ok, %{frames: frames}} =
  Melee.Bot.run(MultishineBot,
    path: Path.expand(System.fetch_env!("MELEE_DOLPHIN_PATH")),
    iso_path: Path.expand(System.fetch_env!("MELEE_ISO_PATH")),
    home: Path.join(System.tmp_dir!(), "melee_multishine_bot"),
    headless: not windowed?,
    gfx_backend: if(windowed?, do: "OGL", else: "Null"),
    console: [polling_mode: true, polling_timeout: 100],
    character: :fox,
    stage: :final_destination,
    opponent: [character: :falco]
  )

IO.puts("game over after #{frames} frames")
