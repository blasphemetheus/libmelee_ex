# Drive a real Dolphin through the in-game nametag flow with
# `Melee.Probe`. Reusable: this is the script to reach for when the
# nametag coordinates or the CSS flow need re-checking against a build.
#
# `Melee.Probe` is test-only, so run this under the test env:
#
#     MIX_ENV=test mix run examples/nametag_session.exs create
#     MIX_ENV=test mix run examples/nametag_session.exs select
#     MIX_ENV=test mix run examples/nametag_session.exs diagnose
#
#   create    wipe the home, provision a card, answer Melee's boot
#             prompts and register the tag. Ends parked at the CSS so
#             the nameplate can be eyeballed.
#   select    pick the already-saved tag, start a match against a CPU,
#             and print the nametag the GAME_START event carried.
#   diagnose  same as select, but logs every input to the autostart
#             decision each half-second. Use when a run stalls at the
#             CSS and you need to see WHICH gate is false.
#
# Configure with env vars:
#   MELEE_DOLPHIN_PATH  Slippi Dolphin AppImage (required)
#   MELEE_ISO_PATH      Melee ISO (required)
#   MELEE_NAMETAG_HOME  Dolphin user dir (default /tmp/melee_nametag_session)
#   MELEE_NAMETAG       tag to create/select (default EXPH)

require Logger
alias Melee.{Dolphin, Enums, Probe}

mode =
  case System.argv() do
    ["create"] -> :create
    ["diagnose"] -> :diagnose
    ["select"] -> :select
    other -> raise "usage: nametag_session.exs create|select|diagnose (got #{inspect(other)})"
  end

fetch_env = fn name ->
  System.get_env(name) || raise "#{name} is not set"
end

path = Path.expand(fetch_env.("MELEE_DOLPHIN_PATH"))
iso = Path.expand(fetch_env.("MELEE_ISO_PATH"))
home = System.get_env("MELEE_NAMETAG_HOME", "/tmp/melee_nametag_session")
tag = System.get_env("MELEE_NAMETAG", "EXPH")

if mode == :create do
  Logger.info("[nametag] wiping #{home} so the card and boot prompts are exercised")
  File.rm_rf!(home)
end

probe =
  Probe.start!(
    path: path,
    iso_path: iso,
    home: home,
    slippi_port: 51_601,
    headless: false,
    gfx_backend: "OGL",
    memory_card: :folder,
    blocking_input: false,
    ports: if(mode == :create, do: [1], else: [1, 2])
  )

Logger.info("[nametag] card folder: #{Dolphin.gci_folder_path(home)}")

fd = Enums.Stage.to_id(:final_destination)

bot = [
  port: 1,
  character: Enums.Character.to_id(:fox),
  stage: fd,
  nametag: tag,
  nametag_mode: if(mode == :create, do: :create, else: :select)
]

cpu = [port: 2, character: Enums.Character.to_id(:falco), stage: fd, cpu_level: 9]

# Everything the autostart decision depends on, in one line.
report = fn probe ->
  gamestate = probe.gamestate
  p1 = gamestate.players[1]
  p2 = gamestate.players[2]

  Logger.info(
    "[nametag] frames=#{probe.frames} menu=#{gamestate.menu_state} " <>
      "ready=#{gamestate.ready_to_start} " <>
      "| p1 char=#{p1 && p1.character} coin=#{p1 && p1.coin_down} " <>
      "cursor=#{inspect(Probe.cursor(probe, 1))} " <>
      "tag_done=#{Probe.helper(probe, 1).nametag_done} " <>
      "| p2 char=#{p2 && p2.character} lvl=#{p2 && p2.cpu_level} " <>
      "status=#{p2 && p2.controller_status} " <>
      "| p2_configured=#{Probe.port_configured?(probe, cpu)} " <>
      "autostart=#{Probe.autostart?(probe, [cpu])}"
  )
end

try do
  case mode do
    :create ->
      probe =
        Probe.drive!(probe, &Probe.helper(&1).nametag_done, bot,
          timeout_frames: 12_000,
          describe: "the nametag to be registered"
        )

      Logger.info("[nametag] registered after #{probe.frames} frames")

      # Keep driving so the character is re-selected and the nameplate
      # is visible, then park.
      probe = Probe.drive!(probe, &(&1.frames > probe.frames + 600), bot, timeout_frames: 900)
      Logger.info("[nametag] parked at the CSS — check the nameplate")

    select_or_diagnose ->
      probe =
        Probe.drive!(
          probe,
          fn probe ->
            if select_or_diagnose == :diagnose and rem(probe.frames, 30) == 0 do
              report.(probe)
            end

            Probe.at_menu?(probe, :in_game)
          end,
          # READY TO FIGHT lands the instant port 2 is filled, long
          # before its CPU level is dragged in, so gate START on port 2
          # actually being configured.
          fn probe -> [bot ++ [autostart: Probe.autostart?(probe, [cpu])], cpu] end,
          timeout_frames: 20_000,
          describe: "the match to start"
        )

      Logger.info(
        "[nametag] in game after #{probe.frames} frames — " <>
          "port 1 nametag = #{inspect(probe.gamestate.players[1].nametag)}"
      )
  end
after
  Probe.stop(probe)
end
