defmodule Melee.Integration.NetplayDirectTest do
  use ExUnit.Case

  @moduledoc """
  End-to-end check of Slippi Direct netplay: two Dolphin instances, two
  real Slippi accounts, and actual matchmaking — both sides driven by
  this library.

  Excluded by default; it launches two Dolphins and talks to Slippi's
  matchmaking servers. To run it:

      MELEE_NETPLAY_DOLPHIN_PATH=~/.local/share/slippi/netplay/Slippi_Online-x86_64.AppImage \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      MELEE_HOME_A=~/.config/SlippiOnline-bot \\
      MELEE_CODE_A='EXPH#288' \\
      MELEE_HOME_B=~/.config/SlippiOnline \\
      MELEE_CODE_B='DBTD#411' \\
      mix test --only netplay_direct

  Each side connects to the *other* side's code, so no human is needed.

  ## Two things this is really testing

  `own_port` detection is the point. Slippi assigns in-game ports per
  session, so a bot cannot assume it is the port it configured — and
  when it guesses wrong, everything downstream (state embeddings,
  rewards) silently refers to the opponent. The assertion below is that
  each side independently resolves *itself* from the connect codes, and
  that the two sides disagree about which port they are, because the
  assignment really is asymmetric.

  Also covered: the Direct menu flow (`MenuHelper` entering a connect
  code on the name-entry keyboard) and `copy_home_from` bringing a
  logged-in Slippi account into a session's user directory.

  ## Build requirement

  Slippi Direct does **not** work on the ExiAI Ishiiruka build — its
  online menu is inert there (verified against a Python libmelee oracle,
  which froze at the same spot). Use the netplay-stable build. `Null`
  video keeps it windowless.
  """

  alias Melee.{Enums, Probe}

  @moduletag :dolphin
  @moduletag :netplay_direct
  @moduletag timeout: 900_000

  # Matchmaking is the slow part and is out of our hands, so this is
  # generous. Frames-in-game is what actually proves the connection.
  @in_game_frames 300

  # Wall clock, NOT probe step counts (polling coalesces those). Booting
  # two Dolphins and finding each other cannot happen in seconds.
  @min_run_ms 10_000

  setup_all do
    env = fn name -> System.get_env(name) end

    config = %{
      path: env.("MELEE_NETPLAY_DOLPHIN_PATH") || env.("MELEE_DOLPHIN_PATH"),
      iso: env.("MELEE_ISO_PATH"),
      home_a: env.("MELEE_HOME_A"),
      code_a: env.("MELEE_CODE_A"),
      home_b: env.("MELEE_HOME_B"),
      code_b: env.("MELEE_CODE_B")
    }

    missing = for {k, v} <- config, v == nil, do: k

    if missing == [] do
      {:ok,
       Map.new(config, fn
         {k, v} when k in [:path, :iso, :home_a, :home_b] -> {k, Path.expand(v)}
         {k, v} -> {k, v}
       end)}
    else
      {:ok, skip: "set #{Enum.map_join(missing, ", ", &to_string/1)}"}
    end
  end

  test "two bots connect over Slippi Direct and each resolves its own port", ctx do
    if ctx[:skip] do
      IO.puts("\n[netplay] skipped: #{ctx.skip}")
    else
      # Each side runs in its own process: both must be stepping their
      # console at the same time for matchmaking to complete.
      side_a =
        Task.async(fn -> play_side(ctx, "A", ctx.home_a, ctx.code_b, 51_570) end)

      # Stagger slightly so the two Dolphins are not hammering
      # matchmaking at the same instant.
      Process.sleep(5_000)

      side_b =
        Task.async(fn -> play_side(ctx, "B", ctx.home_b, ctx.code_a, 51_571) end)

      result_a = Task.await(side_a, 600_000)
      result_b = Task.await(side_b, 600_000)

      assert %{own_port: port_a, codes: codes_a, elapsed_ms: ms_a} = result_a
      assert %{own_port: port_b, codes: codes_b} = result_b

      # Both sides actually got into a game together.
      assert port_a != nil, "side A never resolved its own port: #{inspect(result_a)}"
      assert port_b != nil, "side B never resolved its own port: #{inspect(result_b)}"

      # The heart of it: Slippi handed the two accounts different ports,
      # and each side worked out which one it is.
      assert port_a != port_b,
             "both sides claim port #{port_a}; own_port detection is not resolving per-side"

      # Each side's own port is the one carrying its OWN connect code.
      assert normalize(codes_a[port_a]) == normalize(ctx.code_a)
      assert normalize(codes_b[port_b]) == normalize(ctx.code_b)

      # ...and both saw the same pair of players, from opposite seats.
      assert normalize(codes_a[port_b]) == normalize(ctx.code_b)

      assert ms_a > @min_run_ms,
             "expected a real boot-and-matchmake, only ran #{ms_a}ms"

      IO.puts(
        "\n[netplay] A=#{ctx.code_a} own_port=#{port_a} | " <>
          "B=#{ctx.code_b} own_port=#{port_b} | #{ms_a}ms"
      )
    end
  end

  # Drive one side: boot, enter the opponent's code, play a few hundred
  # frames, and report what the connection looked like.
  defp play_side(ctx, label, home, opponent_code, slippi_port) do
    probe =
      Probe.start!(
        path: ctx.path,
        iso_path: ctx.iso,
        copy_home_from: home,
        slippi_port: slippi_port,
        headless: false,
        gfx_backend: "Null",
        blocking_input: false,
        boot_timeout: 120_000,
        ports: [1]
      )

    try do
      opts = [
        port: 1,
        character: Enums.Character.to_id(:fox),
        stage: Enums.Stage.to_id(:battlefield),
        connect_code: opponent_code,
        autostart: true
      ]

      # Getting in-game at all means the Direct flow worked: the code was
      # typed on the name-entry keyboard and matchmaking paired us.
      probe =
        Probe.drive!(probe, &Probe.at_menu?(&1, :in_game), opts,
          timeout_frames: 40_000,
          describe: "side #{label} to connect over Direct"
        )

      # Play a little so this is a real session, not just a handshake.
      probe = Probe.advance!(probe, @in_game_frames)

      gamestate = Probe.gamestate(probe)

      %{
        own_port: own_port(gamestate, opponent_code),
        codes: connect_codes(gamestate),
        frame: gamestate.frame,
        elapsed_ms: Probe.elapsed_ms(probe)
      }
    after
      Probe.stop(probe)
    end
  end

  # We know the OPPONENT's code (we searched for it), so we are the other
  # tagged player. This mirrors what ExPhil.Bridge.MeleePort does.
  defp own_port(gamestate, opponent_code) do
    opponent = normalize(opponent_code)

    codes =
      for {port, player} <- gamestate.players,
          player != nil,
          normalize(player.connectCode) != "",
          into: %{},
          do: {port, normalize(player.connectCode)}

    case for({port, code} <- codes, code != opponent, do: port) do
      [port] -> port
      _ -> nil
    end
  end

  defp connect_codes(gamestate) do
    for {port, player} <- gamestate.players, player != nil, into: %{} do
      {port, player.connectCode || ""}
    end
  end

  defp normalize(nil), do: ""
  defp normalize(code), do: code |> String.trim() |> String.upcase()
end
