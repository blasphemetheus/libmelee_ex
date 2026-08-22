defmodule Melee.MemoryHunt do
  @moduledoc """
  The address-hunt kit: pure helpers for re-deriving RAM addresses with
  `Melee.MemoryWatcher` as the probe (MEMORY_WATCH_PROGRAM, the CSS
  re-derivation thread).

  The differential method, as data flow:

      candidates/3    -> a batch of watch lines covering a region
      (idle phase)    -> snapshot A ... snapshot B, nothing driven
      (driven phase)  -> snapshot C ... snapshot D, state commanded
      changed/2       -> keys that moved in each phase
      correlated/2    -> driven-changed MINUS idle-changed = the survivors
      f32_class/1     -> stale-read triage on a survivor's bits
      tracks?/2       -> the closing argument: observed f32 follows
                         commanded coordinates

  Everything here is pure and enumerable by input class; the live
  driver (`examples/memory_hunt_css.exs`) is a thin loop around it.

  ## Data definitions

      Region    = {base, count, stride}   ; 4-aligned u32 addresses,
                                          ; wholly inside MEM1 virtual
      Snapshot  = %{key => u32}           ; MemoryWatcher.snapshot/1
      Change    = {key, before | nil, after}
                                          ; nil before = first observation
                                          ; (on-change semantics: "appeared"
                                          ;  IS "changed since boot")
      F32Class  = :zero | :denormal | :normal | :nan_or_inf
      Pair      = {observed :: number | :nan | :infinity | :neg_infinity,
                   commanded :: number}
  """

  @mem1_lo 0x8000_0000
  @mem1_hi 0x817F_FFFF

  @doc """
  Watch lines covering `count` u32 slots from `base` every `stride`
  bytes. Names are `:"h_<HEXADDR>"` so hunt watches never collide with
  `Melee.MemoryMap` names. Raises if the region leaves MEM1 virtual or
  is misaligned — a silent out-of-range watch reads 0 forever and
  poisons the differential.
  """
  @spec candidates(non_neg_integer(), pos_integer(), pos_integer()) :: [{atom(), String.t()}]
  def candidates(base, count, stride \\ 4)
      when rem(base, 4) == 0 and rem(stride, 4) == 0 and stride > 0 and count > 0 do
    last = base + (count - 1) * stride

    unless base >= @mem1_lo and last + 3 <= @mem1_hi do
      raise ArgumentError,
            "region #{hex(base)}..#{hex(last)} leaves MEM1 virtual " <>
              "(#{hex(@mem1_lo)}..#{hex(@mem1_hi)})"
    end

    for i <- 0..(count - 1) do
      addr = hex(base + i * stride)
      {:"h_#{addr}", addr}
    end
  end

  @doc """
  Keys whose value moved between two snapshots, as `Change` triples
  (sorted by key). A key present only in `before` is impossible under
  on-change semantics (snapshots only grow) and is ignored.
  """
  @spec changed(map(), map()) :: [{term(), non_neg_integer() | nil, non_neg_integer()}]
  def changed(before, after_) do
    after_
    |> Enum.filter(fn {k, v} -> Map.get(before, k, :absent) != v end)
    |> Enum.map(fn {k, v} -> {k, Map.get(before, k), v} end)
    |> Enum.sort()
  end

  @doc """
  The differential verdict: keys that changed under the DRIVEN phase
  but not under the IDLE phase. Accepts `Change` lists or bare keys;
  returns sorted keys. This is the step that kills always-ticking
  counters (frame counters, RNG) — they change idle too.
  """
  @spec correlated([term()], [term()]) :: [term()]
  def correlated(driven_changed, idle_changed) do
    idle = MapSet.new(idle_changed, &key_of/1)

    driven_changed
    |> Enum.map(&key_of/1)
    |> Enum.reject(&MapSet.member?(idle, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Stale-read triage on a u32's bits as a big-endian f32.

  `:denormal` (exponent 0, mantissa nonzero — the `~1e-39` reads) and
  `:nan_or_inf` are the observed signatures of a WRONG address when a
  float was expected; `:normal` (incl. negative-zero and ordinary
  magnitudes) is what a live cursor/position looks like; `:zero` is
  ambiguous (unwritten OR a legitimate 0.0).
  """
  @spec f32_class(non_neg_integer()) :: :zero | :denormal | :normal | :nan_or_inf
  def f32_class(u32) when u32 in [0x0000_0000, 0x8000_0000], do: :zero

  def f32_class(u32) when is_integer(u32) and u32 >= 0 and u32 <= 0xFFFF_FFFF do
    <<_sign::1, exponent::8, mantissa::23>> = <<u32::32>>

    cond do
      exponent == 0xFF -> :nan_or_inf
      exponent == 0 and mantissa != 0 -> :denormal
      true -> :normal
    end
  end

  @doc """
  The closing argument for a float address: every observed value sits
  within `tol` of its commanded value. Non-numeric observations
  (`:nan`, `:infinity`, `:neg_infinity`, `nil`) fail — a candidate
  that ever decodes to junk while being commanded is not the address.
  Empty pairs are `false`: no evidence is not a pass.
  """
  @spec tracks?([{term(), number()}], number()) :: boolean()
  def tracks?(pairs, tol \\ 3.0)
  def tracks?([], _tol), do: false

  def tracks?(pairs, tol) when is_list(pairs) do
    Enum.all?(pairs, fn
      {observed, commanded} when is_number(observed) -> abs(observed - commanded) <= tol
      {_junk, _commanded} -> false
    end)
  end

  defp key_of({k, _before, _after}), do: k
  defp key_of(k), do: k

  defp hex(n), do: n |> Integer.to_string(16) |> String.pad_leading(8, "0")
end
