defmodule Melee.Cursor do
  @moduledoc """
  Menu-cursor primitives over a live `Melee.Session`: walk a port's
  hand to a coordinate, and press a button the way Melee's CSS actually
  accepts presses.

  Promoted out of test support (`Melee.Probe` carries the originals)
  because library features need them too — `Melee.Match`'s Team Battle
  flow drives the mode toggle and team-color chips with these.

  Two rules from live measurement (docs/melee-menus.md) are baked in:

    * a menu cursor ACCELERATES under a held tilt, so steering eases
      off near the target instead of sailing past it;
    * a press straight after arriving is SWALLOWED by the CSS —
      `settled_tap/4` idles the hand first, then presses.

  Every function pumps the session's frames — Dolphin does not advance
  unless stepped — and returns `{:ok, gamestate}` with the latest
  frame, or `{:error, :timeout | term()}`.
  """

  alias Melee.{Controller, GameState, Session}

  # A menu cursor moves ~1.2 units/frame at full tilt and accelerates;
  # inside @fine units ease to @fine_tilt (~0.2 units/frame creep).
  @fine 3.0
  @fine_tilt 0.22

  @default_tolerance 0.35
  @default_timeout_frames 900
  @default_settle_frames 60

  @doc """
  Walk `port`'s hand to `{x, y}` and stop there.

  Options: `:tolerance` (default `#{@default_tolerance}`),
  `:timeout_frames` (default `#{@default_timeout_frames}`). Pass
  `x: nil` to steer y only (some menus pin x).
  """
  @spec goto(Session.t(), GenServer.server(), 1..4, number() | nil, number(), keyword()) ::
          {:ok, GameState.t()} | {:error, term()}
  def goto(session, controller, port, x, y, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    timeout = Keyword.get(opts, :timeout_frames, @default_timeout_frames)

    result = steer_loop(session, controller, port, x, y, tolerance, timeout)
    Controller.release_all(controller)
    result
  end

  @doc """
  Idle the hand for `:settle_frames` (default `#{@default_settle_frames}`),
  then press `button` for a few frames and release — one settled press,
  as the CSS requires.
  """
  @spec settled_tap(Session.t(), GenServer.server(), atom(), keyword()) ::
          {:ok, GameState.t()} | {:error, term()}
  def settled_tap(session, controller, button, opts \\ []) do
    settle = Keyword.get(opts, :settle_frames, @default_settle_frames)
    hold = Keyword.get(opts, :hold_frames, 4)
    linger = Keyword.get(opts, :linger_frames, 30)

    with {:ok, _} <- idle(session, controller, settle),
         {:ok, _} <- pump(session, hold, fn -> Controller.press_button(controller, button) end) do
      pump(session, linger, fn -> Controller.release_button(controller, button) end)
    end
  end

  @doc "Release everything and step `frames` frames."
  @spec idle(Session.t(), GenServer.server(), non_neg_integer()) ::
          {:ok, GameState.t()} | {:error, term()}
  def idle(session, controller, frames) do
    pump(session, frames, fn -> Controller.release_all(controller) end)
  end

  ## Internals

  defp steer_loop(_session, _controller, _port, _x, _y, _tolerance, 0), do: {:error, :timeout}

  defp steer_loop(session, controller, port, x, y, tolerance, frames_left) do
    case Session.step(session) do
      {:ok, gamestate} ->
        case gamestate.players[port] do
          %{cursor: cursor} ->
            if within?(cursor, x, y, tolerance) do
              {:ok, gamestate}
            else
              steer(controller, cursor, x, y, tolerance)
              steer_loop(session, controller, port, x, y, tolerance, frames_left - 1)
            end

          _ ->
            Controller.release_all(controller)
            steer_loop(session, controller, port, x, y, tolerance, frames_left - 1)
        end

      nil ->
        steer_loop(session, controller, port, x, y, tolerance, frames_left)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp within?(cursor, x, y, tolerance) do
    abs(cursor.y - y) <= tolerance and (x == nil or abs(cursor.x - x) <= tolerance)
  end

  defp steer(controller, cursor, x, y, tolerance) do
    cond do
      cursor.y < y - tolerance ->
        Controller.tilt_analog(controller, :main, 0.5, 0.5 + tilt(y - cursor.y))

      cursor.y > y + tolerance ->
        Controller.tilt_analog(controller, :main, 0.5, 0.5 - tilt(cursor.y - y))

      x == nil ->
        Controller.tilt_analog(controller, :main, 0.5, 0.5)

      cursor.x < x - tolerance ->
        Controller.tilt_analog(controller, :main, 0.5 + tilt(x - cursor.x), 0.5)

      cursor.x > x + tolerance ->
        Controller.tilt_analog(controller, :main, 0.5 - tilt(cursor.x - x), 0.5)

      true ->
        Controller.tilt_analog(controller, :main, 0.5, 0.5)
    end
  end

  defp tilt(distance) when distance > @fine, do: 0.5
  defp tilt(_distance), do: @fine_tilt

  defp pump(session, frames, fun) do
    Enum.reduce_while(1..max(frames, 1), {:error, :no_frames}, fn _i, acc ->
      fun.()

      case Session.step(session) do
        {:ok, gamestate} -> {:cont, {:ok, gamestate}}
        nil -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
