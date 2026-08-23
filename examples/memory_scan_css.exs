# Park-and-scan CSS cursor hunt (v2 of the address hunt, 2026-08-22).
#
# The differential hunt proved the classic 0x8111xxxx region dry on
# mainline — the cursor heap object relocated. Instead of guessing
# regions, read the emulator's memory DIRECTLY: the beam is dolphin's
# ancestor, so yama ptrace_scope=1 permits /proc/<pid>/mem reads.
# Park the cursor at a known coordinate (the OFFLINE CSS stream
# reports the exact f32), scan all of MEM1 for that bit pattern, move
# the cursor, rescan, intersect. Two passes = the address.
#
#   MIX_ENV=test mix run examples/memory_scan_css.exs
alias Melee.Probe

defmodule Mem1 do
  @mem1_size 0x1800000

  # The emulator is a descendant of the launched os_pid (AppImage
  # wrappers in between). Find the descendant whose maps carries a
  # >=24MB shared rw mapping, and validate it IS MEM1 by checking the
  # scene word at 0x479D30 (verified live: settled scene words there).
  def find(root_pid) do
    # Every >=24MB rw mapping in every descendant is a candidate; the
    # one that holds the settled online... offline CSS scene word
    # <<8, 8, _, 0>>? No — offline VS CSS: <<2, 2, _, 0>> at 0x479D30.
    # We navigate to the OFFLINE CSS here, so demand major=pending=2,
    # minor=0. A permissive validator (any small major, 0x00 allowed)
    # matched a zero-filled emulator heap on the first run — 0 hits
    # across 24MB was the tell.
    for pid <- descendants(root_pid),
        {base, path} <- mappings(pid),
        valid_mem1?(pid, base) do
      {pid, base, path}
    end
    |> Enum.sort_by(fn {_p, _b, path} ->
      if String.contains?(path, "dolphin"), do: 0, else: 1
    end)
    |> List.first()
    |> case do
      nil -> nil
      {pid, base, _path} -> {pid, base}
    end
  end

  defp descendants(root) do
    all =
      for entry <- File.ls!("/proc"),
          pid = Integer.parse(entry),
          match?({_, ""}, pid),
          {p, ""} = pid,
          stat = read_stat(p),
          stat != nil,
          do: {p, stat}

    Stream.iterate([root], fn layer ->
      for {p, ppid} <- all, ppid in layer, do: p
    end)
    |> Enum.take_while(&(&1 != []))
    |> List.flatten()
  end

  defp read_stat(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        # field 4 (after the parenthesized comm, which may contain spaces)
        [_, rest] = String.split(stat, ") ", parts: 2)
        rest |> String.split(" ") |> Enum.at(1) |> String.to_integer()

      _ ->
        nil
    end
  end

  defp mappings(pid) do
    case File.read("/proc/#{pid}/maps") do
      {:ok, maps} ->
        maps
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          with [range, perms | rest] <- String.split(line, " ", trim: true),
               true <- String.starts_with?(perms, "rw"),
               [lo, hi] <- String.split(range, "-"),
               {lo, ""} <- Integer.parse(lo, 16),
               {hi, ""} <- Integer.parse(hi, 16),
               true <- hi - lo >= @mem1_size do
            [{lo, Enum.join(Enum.drop(rest, 3), " ")}]
          else
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  # Strict: the OFFLINE VS CSS scene controller reads <<2, 2, _, 0>>
  # (major = pending = VS, minor = CSS) — verified live all session.
  defp valid_mem1?(pid, base) do
    case pread(pid, base + 0x479D30, 4) do
      {:ok, <<0x02, 0x02, _prev, 0x00>>} -> true
      _ -> false
    end
  end

  def pread(pid, host_addr, size) do
    with {:ok, f} <- :file.open(~c"/proc/#{pid}/mem", [:read, :raw, :binary]),
         {:ok, data} <- :file.pread(f, host_addr, size) do
      :file.close(f)
      {:ok, data}
    end
  end

  @doc "All MEM1 offsets holding the exact 4 bytes, scanning in 4MB chunks."
  def scan(pid, base, pattern) do
    chunk = 0x400000

    for chunk_start <- 0..(@mem1_size - 1)//chunk,
        {:ok, data} = pread(pid, base + chunk_start, chunk),
        {off, _len} <- :binary.matches(data, pattern),
        do: chunk_start + off
  end

  def virtual(offset), do: 0x80000000 + offset
end

f32 = fn x -> <<x::float-big-32>> end
hex = fn v -> v |> Integer.to_string(16) |> String.pad_leading(8, "0") end

probe =
  Probe.start!(
    path:
      Path.expand(
        "~/.config/Slippi Launcher/netplay-beta-nixos/Slippi_Netplay_Mainline-x86_64.AppImage"
      ),
    iso_path: Path.expand("~/isos/melee.iso"),
    slippi_port: 51443,
    memory_card: true,
    ports: [1]
  )

probe = Probe.navigate!(probe, character: 0x02, stage: nil)
IO.puts("[scan] at CSS")

{emu_pid, base} =
  case Mem1.find(probe.dolphin.os_pid) do
    nil -> raise "MEM1 mapping not found under pid #{probe.dolphin.os_pid}"
    found -> found
  end

IO.puts("[scan] emulator pid #{emu_pid}, MEM1 host base 0x#{Integer.to_string(base, 16)}")

# Park -> scan -> park -> scan -> intersect; per-axis.
positions = [{-22.0, 11.5}, {10.0, -5.0}, {17.5, 8.25}]

{_probe, hits_per_pass} =
  Enum.reduce(positions, {probe, []}, fn {x, y}, {p, acc} ->
    p = Probe.goto!(p, x, y)
    Process.sleep(300)
    {sx, sy} = Probe.cursor(p, 1)
    x_hits = Mem1.scan(emu_pid, base, f32.(sx)) |> MapSet.new()
    y_hits = Mem1.scan(emu_pid, base, f32.(sy)) |> MapSet.new()

    IO.puts(
      "[scan] parked (#{Float.round(sx, 2)}, #{Float.round(sy, 2)}): " <>
        "#{MapSet.size(x_hits)} x-hits, #{MapSet.size(y_hits)} y-hits"
    )

    {p, acc ++ [{x_hits, y_hits}]}
  end)

x_addrs = hits_per_pass |> Enum.map(&elem(&1, 0)) |> Enum.reduce(&MapSet.intersection/2)
y_addrs = hits_per_pass |> Enum.map(&elem(&1, 1)) |> Enum.reduce(&MapSet.intersection/2)

IO.puts("[scan] X-INTERSECTION (#{MapSet.size(x_addrs)}):")
for off <- Enum.sort(x_addrs), do: IO.puts("[scan]   cursor_x @ 0x#{hex.(Mem1.virtual(off))}")
IO.puts("[scan] Y-INTERSECTION (#{MapSet.size(y_addrs)}):")
for off <- Enum.sort(y_addrs), do: IO.puts("[scan]   cursor_y @ 0x#{hex.(Mem1.virtual(off))}")

# X/Y of one struct usually sit adjacent — report pairs 4 bytes apart.
pairs =
  for xo <- x_addrs, yo <- y_addrs, yo - xo == 4 do
    {Mem1.virtual(xo), Mem1.virtual(yo)}
  end

IO.puts("[scan] ADJACENT X/Y PAIRS (the cursor struct candidates):")
for {vx, vy} <- Enum.sort(pairs), do: IO.puts("[scan]   {\"#{hex.(vx)}\", \"#{hex.(vy)}\"}")

Probe.stop(probe)
