defmodule Melee.GameEvents.Stats do
  @moduledoc """
  Fold a `Melee.GameEvents` event stream into per-game, per-port
  summaries — the Slippi-stats vocabulary, computed live or from a
  replay with the same code:

      "game.slp"
      |> Melee.SlpFile.stream!()
      |> Melee.GameEvents.stream()
      |> Melee.GameEvents.Stats.summarize()

  Returns a map keyed by port:

    * `:kills` — conversions that ended a stock (`did_kill`)
    * `:conversions` / `:neutral_wins` / `:counter_attacks` / `:trades`
    * `:damage_dealt` — total damage across the port's conversions
    * `:openings_per_kill` — conversions / kills (nil before a kill)
    * `:damage_per_opening`
    * `:l_cancels` — `%{successful: n, missed: n, rate: 0.0..1.0 | nil}`
    * `:stocks_lost` / `:sds`
  """

  @empty %{
    kills: 0,
    conversions: 0,
    neutral_wins: 0,
    counter_attacks: 0,
    trades: 0,
    damage_dealt: 0.0,
    openings_per_kill: nil,
    damage_per_opening: nil,
    l_cancels: %{successful: 0, missed: 0, rate: nil},
    stocks_lost: 0,
    sds: 0
  }

  @doc """
  Summarize an enumerable of events into `%{port => stats}`.

  ## Examples

      iex> events = [
      ...>   {:conversion, %{by: 1, against: 2, damage: 34.5, did_kill: true, opening: :neutral_win, moves: [], start_frame: 0, end_frame: 100}},
      ...>   {:conversion, %{by: 1, against: 2, damage: 12.0, did_kill: false, opening: :trade, moves: [], start_frame: 200, end_frame: 260}},
      ...>   {:l_cancel, %{port: 1, success: true}},
      ...>   {:l_cancel, %{port: 1, success: true}},
      ...>   {:l_cancel, %{port: 1, success: false}},
      ...>   {:stock_lost, %{port: 2, remaining: 3, kind: :ko, percent_before: 98.2}},
      ...>   {:stock_lost, %{port: 1, remaining: 3, kind: :sd, percent_before: 12.0}}
      ...> ]
      iex> stats = Melee.GameEvents.Stats.summarize(events)
      iex> {stats[1].kills, stats[1].conversions, stats[1].damage_dealt}
      {1, 2, 46.5}
      iex> {stats[1].openings_per_kill, stats[1].damage_per_opening}
      {2.0, 23.25}
      iex> stats[1].l_cancels
      %{successful: 2, missed: 1, rate: 0.667}
      iex> {stats[2].stocks_lost, stats[1].sds}
      {1, 1}
  """
  @spec summarize(Enumerable.t()) :: %{optional(1..4) => map()}
  def summarize(events) do
    events
    |> Enum.reduce(%{}, &fold/2)
    |> Map.new(fn {port, stats} -> {port, finalize(stats)} end)
  end

  defp fold({:conversion, c}, acc) do
    update(acc, c.by, fn stats ->
      opening_key =
        case c.opening do
          :neutral_win -> :neutral_wins
          :counter_attack -> :counter_attacks
          :trade -> :trades
        end

      stats
      |> Map.update!(:conversions, &(&1 + 1))
      |> Map.update!(opening_key, &(&1 + 1))
      |> Map.update!(:damage_dealt, &(&1 + c.damage))
      |> Map.update!(:kills, &(&1 + if(c.did_kill, do: 1, else: 0)))
    end)
  end

  defp fold({:l_cancel, %{port: port, success: success}}, acc) do
    key = if success, do: :successful, else: :missed

    update(acc, port, fn stats ->
      Map.update!(stats, :l_cancels, &Map.update!(&1, key, fn n -> n + 1 end))
    end)
  end

  defp fold({:stock_lost, %{port: port, kind: kind}}, acc) do
    update(acc, port, fn stats ->
      stats
      |> Map.update!(:stocks_lost, &(&1 + 1))
      |> Map.update!(:sds, &(&1 + if(kind == :sd, do: 1, else: 0)))
    end)
  end

  defp fold(_event, acc), do: acc

  defp update(acc, port, fun) do
    Map.update(acc, port, fun.(@empty), fun)
  end

  defp finalize(stats) do
    %{successful: ok, missed: missed} = stats.l_cancels

    stats
    |> Map.put(
      :openings_per_kill,
      if(stats.kills > 0, do: Float.round(stats.conversions / stats.kills, 2))
    )
    |> Map.put(
      :damage_per_opening,
      if(stats.conversions > 0, do: Float.round(stats.damage_dealt / stats.conversions, 2))
    )
    |> Map.put(:damage_dealt, Float.round(stats.damage_dealt, 2))
    |> put_in([:l_cancels, :rate], if(ok + missed > 0, do: Float.round(ok / (ok + missed), 3)))
  end
end
