defmodule Melee.MemoryDump do
  @moduledoc """
  Direct reads of a live emulator's MEM1 via `/proc/<pid>/mem` — the
  park-and-scan / dump-diff side of the address-hunt kit
  (`Melee.MemoryHunt` is the watcher-differential side).

  Works because the beam LAUNCHES dolphin: yama ptrace_scope=1 permits
  an ancestor to read a descendant's memory. Two proven methods
  (2026-08-22, the CSS cursor re-derivation):

    * **park-and-scan**: park a value you control at a known float
      (the offline CSS stream reports exact f32s), `scan/3` MEM1 for
      the bit pattern, move, rescan, intersect — the survivors are
      the addresses.
    * **dump-diff**: `dump/2` full MEM1 before and after ONE discrete
      action (an A press) at an otherwise SETTLED screen — settled
      menu memory is static, so the diff isolates exactly the state
      that action touched.

  MEM1 discovery validates by demanding a KNOWN value (the scene word
  at +0x479D30) — a permissive validator once matched a zero-filled
  emulator heap and scanned 24MB of nothing.
  """

  @mem1_size 0x1800000
  @scene_word_offset 0x479D30

  @doc "MEM1 byte size (GameCube: 24MB)."
  def mem1_size, do: @mem1_size

  @doc """
  Find the emulator process and MEM1 host base under `root_pid`:
  `{emulator_pid, host_base}` or `nil`. `expected_scene` is the byte
  pattern demanded at +0x479D30 (e.g. `<<0x02, 0x02>>` for a settled
  offline VS scene — matched as a PREFIX of the word).
  """
  def find_mem1(root_pid, expected_scene) do
    prefix_size = byte_size(expected_scene)

    Enum.find_value(descendants(root_pid), fn pid ->
      Enum.find_value(mappings(pid), fn {base, _path} ->
        case pread(pid, base + @scene_word_offset, 4) do
          {:ok, <<prefix::binary-size(prefix_size), _::binary>>}
          when prefix == expected_scene ->
            {pid, base}

          _ ->
            nil
        end
      end)
    end)
  end

  @doc "Read `size` bytes at `host_addr` from `pid`'s memory."
  def pread(pid, host_addr, size) do
    with {:ok, f} <- :file.open(~c"/proc/#{pid}/mem", [:read, :raw, :binary]),
         {:ok, data} <- :file.pread(f, host_addr, size) do
      :file.close(f)
      {:ok, data}
    end
  end

  @doc "Full MEM1 as one binary (24MB — hold at most two of these)."
  def dump(pid, base) do
    chunks =
      for start <- 0..(@mem1_size - 1)//0x400000 do
        {:ok, data} = pread(pid, base + start, 0x400000)
        data
      end

    IO.iodata_to_binary(chunks)
  end

  @doc "All MEM1 offsets holding the exact byte `pattern`."
  def scan(pid, base, pattern) do
    for start <- 0..(@mem1_size - 1)//0x400000,
        {:ok, data} = pread(pid, base + start, 0x400000),
        {off, _len} <- :binary.matches(data, pattern),
        do: start + off
  end

  @doc """
  u32-aligned diff of two equal-size dumps:
  `[{offset, before_u32, after_u32}]`. The dump-diff workhorse.
  """
  def diff(before, after_) when byte_size(before) == byte_size(after_) do
    diff_words(before, after_, 0, [])
  end

  defp diff_words(<<a::32, ra::binary>>, <<b::32, rb::binary>>, off, acc) do
    acc = if a == b, do: acc, else: [{off, a, b} | acc]
    diff_words(ra, rb, off + 4, acc)
  end

  defp diff_words(<<>>, <<>>, _off, acc), do: Enum.reverse(acc)

  @doc "MEM1 offset -> in-game virtual address."
  def virtual(offset), do: 0x80000000 + offset

  ## /proc plumbing

  @doc false
  def descendants(root) do
    all =
      for entry <- File.ls!("/proc"),
          {p, ""} <- [Integer.parse(entry)],
          ppid = parent_of(p),
          ppid != nil,
          do: {p, ppid}

    Stream.iterate([root], fn layer ->
      for {p, ppid} <- all, ppid in layer, do: p
    end)
    |> Enum.take_while(&(&1 != []))
    |> List.flatten()
  end

  defp parent_of(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        [_, rest] = String.split(stat, ") ", parts: 2)
        rest |> String.split(" ") |> Enum.at(1) |> String.to_integer()

      _ ->
        nil
    end
  end

  @doc false
  def mappings(pid) do
    case File.read("/proc/#{pid}/maps") do
      {:ok, maps} -> parse_maps(maps)
      _ -> []
    end
  end

  @doc """
  Pure: rw mappings of at least MEM1 size from a `/proc/<pid>/maps`
  content string, as `[{start_addr, path}]`.
  """
  def parse_maps(content) do
    content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      with [range, perms | rest] <- String.split(line, " ", trim: true),
           true <- String.starts_with?(perms, "rw"),
           [lo, hi] <- String.split(range, "-"),
           {lo, ""} <- Integer.parse(lo, 16),
           {hi, ""} <- Integer.parse(hi, 16),
           true <- hi - lo >= @mem1_size do
        [{lo, rest |> Enum.drop(3) |> Enum.join(" ")}]
      else
        _ -> []
      end
    end)
  end
end
