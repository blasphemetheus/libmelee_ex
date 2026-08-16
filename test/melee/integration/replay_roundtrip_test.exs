defmodule Melee.Integration.ReplayRoundtripTest do
  use ExUnit.Case

  @moduledoc """
  The loop, closed: a bot plays a game live, Slippi records it, and the
  written `.slp` decodes to the SAME game.

  Fox multishines for #{600} frames while we count shine entries from
  the LIVE spectator stream; then the game is quit, and the replay
  Dolphin wrote is parsed with `Melee.SlpFile` + `Melee.GameEvents`.
  One assertion ties four things together — the input path, the live
  decoder, Slippi's recorder, and the file decoder: the shine count in
  the file must equal the count seen live.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_replay
  """

  alias Melee.{Controller, Enums, GameEvents, Match, Session, SlpFile}

  @moduletag :dolphin
  @moduletag :dolphin_replay
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_replay_rt_it")
  @replay_dir Path.join(@home, "replays")

  @standing Enums.Action.to_id(:standing)
  @knee_bend Enums.Action.to_id(:knee_bend)
  @shine_ground_start Enums.Action.to_id(:down_b_ground_start)
  @shine_ground Enums.Action.to_id(:down_b_ground)
  @shine_stun Enums.Action.to_id(:down_b_stun)
  @shine_air Enums.Action.to_id(:down_b_air)

  @shine_states MapSet.new([@shine_ground_start, @shine_air])

  @play_frames 600

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

  test "the replay Slippi writes decodes to the game we played", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      {:ok, session} =
        Session.start_link(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_589,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          blocking_input: true,
          ports: [1, 2],
          replay_dir: @replay_dir,
          console: [polling_mode: true, polling_timeout: 100]
        )

      on_exit(fn -> safe_stop(session) end)

      {:ok, first} =
        Match.play(session,
          p1: [character: :fox],
          p2: [character: :falco],
          stage: :final_destination
        )

      controller = Session.controller(session, 1)

      # Settle out of the entry animation, then multishine and count
      # shine entries from the live stream.
      {_gs, _} = idle(session, controller, first, 90)
      {live_shines, _gs} = play(session, controller, @play_frames)

      {:ok, _after_quit} = Match.quit(session, controller)

      # Slippi finalizes the file at GAME_END; give the writer a moment.
      Process.sleep(500)
      assert :ok = Session.stop(session)

      assert [replay] = Path.wildcard(Path.join(@replay_dir, "**/*.slp")),
             "expected exactly one replay in #{@replay_dir}"

      frames = replay |> SlpFile.stream!() |> Enum.to_list()
      file_shines = entries(Enum.map(frames, &(&1.players[1] && &1.players[1].action)))

      events = frames |> GameEvents.stream() |> Enum.to_list()

      assert [{:game_start, %{stage: stage, players: players}} | _] = events
      assert stage == Enums.Stage.to_id(:final_destination)
      assert players[1] == Enums.Character.to_id(:fox)
      assert players[2] == Enums.Character.to_id(:falco)
      assert match?({:game_end, _}, List.last(events))

      IO.puts(
        "\n[dolphin] replay_roundtrip: live=#{live_shines} file=#{file_shines} " <>
          "frames=#{length(frames)} (#{Path.basename(replay)})"
      )

      # The heart of the test: the file must contain the game we played.
      assert file_shines == live_shines
      assert live_shines >= 60
    end
  end

  defp idle(_session, controller, gamestate, 0), do: {gamestate, controller}

  defp idle(session, controller, gamestate, n) do
    Controller.release_all(controller)

    case Session.step(session) do
      {:ok, next} -> idle(session, controller, next, n - 1)
      nil -> idle(session, controller, gamestate, n)
    end
  end

  defp play(session, controller, frames) do
    {actions, _} =
      Enum.reduce(1..frames, {[], nil}, fn _i, {actions, gs} ->
        if gs, do: multishine(gs.players[1], controller)

        case Session.step(session) do
          {:ok, next} -> {[next.players[1] && next.players[1].action | actions], next}
          nil -> {actions, gs}
        end
      end)

    {entries(Enum.reverse(actions)), nil}
  end

  defp entries(actions) do
    actions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] ->
      not MapSet.member?(@shine_states, a) and MapSet.member?(@shine_states, b)
    end)
  end

  defp multishine(nil, controller), do: Controller.release_all(controller)

  defp multishine(p, controller) do
    cond do
      p.action == @standing ->
        Controller.press_button(controller, :b)
        Controller.tilt_analog(controller, :main, 0.5, 0.0)

      p.action == @knee_bend and p.action_frame == 3 ->
        Controller.press_button(controller, :b)
        Controller.tilt_analog(controller, :main, 0.5, 0.0)

      p.action == @knee_bend ->
        Controller.release_button(controller, :b)

      p.action in [@shine_ground_start, @shine_stun] and p.action_frame >= 3 and p.on_ground ->
        Controller.release_button(controller, :b)
        Controller.press_button(controller, :y)

      p.action == @shine_ground ->
        Controller.press_button(controller, :y)

      true ->
        Controller.release_all(controller)
    end
  end

  defp safe_stop(session) do
    Session.stop(session)
  catch
    _, _ -> :ok
  end
end
