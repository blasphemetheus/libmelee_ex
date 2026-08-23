# Differential address hunt at the offline VS CSS — the live driver
# around the pure Melee.MemoryHunt kit (MEMORY_WATCH_PROGRAM, CSS
# re-derivation thread).
#
#   HUNT_BASE=81118D00 HUNT_COUNT=100 HUNT_STRIDE=4 \
#     MIX_ENV=test mix run examples/memory_hunt_css.exs
#
# Method: candidates over the region + canary -> navigate to CSS ->
# IDLE phase (nothing driven; whatever changes is ambient noise) ->
# DRIVEN phase (cursor commanded to known coordinates, snapshot after
# each) -> correlated survivors -> f32 triage -> tracks? verdict per
# survivor against the commanded path.
alias Melee.{MemoryHunt, MemoryMap, MemoryWatcher, Probe}

base = System.get_env("HUNT_BASE", "81118D00") |> String.to_integer(16)
count = System.get_env("HUNT_COUNT", "100") |> String.to_integer()
stride = System.get_env("HUNT_STRIDE", "4") |> String.to_integer()

candidates = MemoryHunt.candidates(base, count, stride)
IO.puts("[hunt] #{count} candidates from #{Integer.to_string(base, 16)} stride #{stride}")

probe =
  Probe.start!(
    path:
      Path.expand(
        "~/.config/Slippi Launcher/netplay-beta-nixos/Slippi_Netplay_Mainline-x86_64.AppImage"
      ),
    iso_path: Path.expand("~/isos/melee.iso"),
    slippi_port: 51443,
    memory_card: true,
    memory_watch: MemoryMap.canary() ++ candidates,
    ports: [1]
  )

w = probe.dolphin.memory_watcher
probe = Probe.navigate!(probe, character: 0x02, stage: nil)
IO.puts("[hunt] at CSS; canary rng=#{inspect(MemoryWatcher.get(w, :rng_seed))}")

# Liveness probe between phases: traffic must keep climbing or the
# watcher/pacing died and every later snapshot is a frozen lie
# (2026-08-22 first run: 74 idle movers then "driven movers: 0" —
# a stalled watcher, not a quiet region).
liveness = fn label ->
  t0 = MemoryWatcher.traffic(w)
  Process.sleep(500)
  t1 = MemoryWatcher.traffic(w)
  IO.puts("[hunt] liveness @#{label}: traffic +#{t1 - t0}/500ms#{if t1 == t0, do: "  <-- STALLED", else: ""}")
  t1 > t0
end

# IDLE phase: ambient movers (frame counters, RNG-adjacent, animation).
idle_a = MemoryWatcher.snapshot(w)
Process.sleep(3_000)
idle_b = MemoryWatcher.snapshot(w)
idle_changed = MemoryHunt.changed(idle_a, idle_b)
IO.puts("[hunt] idle movers: #{length(idle_changed)}")
liveness.("post-idle")

# DRIVEN phase: command the cursor through known coordinates, snapshot
# after each so survivors can be tracks?-verified per position.
# NOTE: rebind probe through goto! (mw_verify pattern) — the struct
# carries session state.
path = [{-22.0, 11.5}, {10.0, -5.0}, {-5.0, -18.0}, {20.0, 15.0}]
pre_drive = MemoryWatcher.snapshot(w)

{probe, per_position} =
  Enum.reduce(path, {probe, []}, fn {x, y}, {p, acc} ->
    p = Probe.goto!(p, x, y)
    Process.sleep(300)
    {p, [{{x, y}, MemoryWatcher.snapshot(w)} | acc]}
  end)

per_position = Enum.reverse(per_position)
liveness.("post-drive")

{_last_pos, post_drive} = List.last(per_position)
driven_changed = MemoryHunt.changed(pre_drive, post_drive)
survivors = MemoryHunt.correlated(driven_changed, idle_changed)
IO.puts("[hunt] driven movers: #{length(driven_changed)}; SURVIVORS: #{length(survivors)}")

get_f32 = fn snapshot, key ->
  case Map.get(snapshot, key) do
    nil ->
      nil

    u32 ->
      case <<u32::32>> do
        <<f::float-big-32>> -> f
        _ -> :nan
      end
  end
end

for key <- survivors do
  {:ok, latest} = MemoryWatcher.get(w, key)
  class = MemoryHunt.f32_class(latest)

  x_pairs = for {{cx, _cy}, snap} <- per_position, do: {get_f32.(snap, key), cx}
  y_pairs = for {{_cx, cy}, snap} <- per_position, do: {get_f32.(snap, key), cy}

  verdict =
    cond do
      MemoryHunt.tracks?(x_pairs) -> "TRACKS CURSOR X"
      MemoryHunt.tracks?(y_pairs) -> "TRACKS CURSOR Y"
      true -> "moved, no coordinate match"
    end

  IO.puts("[hunt] #{key} latest=#{Integer.to_string(latest, 16)} f32=#{inspect(class)} — #{verdict}")
end

Probe.stop(probe)
