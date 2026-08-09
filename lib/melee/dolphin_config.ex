defmodule Melee.DolphinConfig do
  @moduledoc """
  Helpers to wire a `Melee.Controller` into a Dolphin user directory.

  Ports the controller-setup slice of libmelee's `Console`:
  creating the input fifo and writing the `GCPadNew.ini` pad mapping and
  `Dolphin.ini` `SIDevice` entry for a port. Dolphin process management
  (launching, ISO paths, home-directory scaffolding) is intentionally out
  of scope — drive that from your application.

  `dolphin_home` is Dolphin's *user* directory (the one containing
  `Config/` and `Pipes/`), not the install directory.
  """

  @type gc_port :: 1..4

  # Dolphin.ini SIDevice values (enums.ControllerType)
  @sidevice %{standard: "6", gcn_adapter: "12", unplugged: "0"}

  @doc "The fifo path for a controller port under a Dolphin home directory."
  @spec pipes_path(Path.t(), gc_port()) :: Path.t()
  def pipes_path(dolphin_home, port), do: Path.join([dolphin_home, "Pipes", "slippibot#{port}"])

  @doc """
  Declare the COMPLETE controller layout for a session: every one of the
  four ports gets an explicit SIDevice, so nothing inherited from a
  config template or a previous session survives. Ports absent from
  `ports` are written `:unplugged`.

  In particular, a session that declares no `:gcn_adapter` port will
  never claim the GC adapter's USB device — libusb allows only one
  claimant, so a bot Dolphin that inherits adapter ports blocks the
  human's own Slippi session from using the controller (the 2026-08-09
  adapter fight: libmelee's template leaves ports 3/4 on SIDevice 12 in
  every spawned instance).

  `ports` maps port number to type, e.g. `%{1 => :standard, 2 => :standard}`
  for a bot-vs-CPU session, or `%{1 => :standard, 2 => :gcn_adapter}`
  for a local human-vs-bot showcase.

  Returns `{:ok, %{port => fifo_path}}` covering the `:standard` ports.
  """
  @spec declare_ports(Path.t(), %{optional(gc_port()) => :standard | :gcn_adapter | :unplugged}) ::
          {:ok, %{gc_port() => Path.t()}} | {:error, term()}
  def declare_ports(dolphin_home, ports) when is_map(ports) do
    Enum.reduce_while(1..4, {:ok, %{}}, fn port, {:ok, pipes} ->
      type = Map.get(ports, port, :unplugged)

      case setup_controller(dolphin_home, port, type) do
        {:ok, pipe} when type == :standard -> {:cont, {:ok, Map.put(pipes, port, pipe)}}
        {:ok, _} -> {:cont, {:ok, pipes}}
        {:error, reason} -> {:halt, {:error, {:port, port, reason}}}
      end
    end)
  end

  @doc """
  Create the input fifo and write pad + SIDevice config for `port`.

  `type` is `:standard` (bot pipe input), `:gcn_adapter`, or `:unplugged`.
  Returns the fifo path on success.

  Prefer `declare_ports/2` for whole-session setup — it also unplugs the
  ports you are NOT using, which is what keeps a bot Dolphin from
  claiming the GC adapter.
  """
  @spec setup_controller(Path.t(), gc_port(), :standard | :gcn_adapter | :unplugged) ::
          {:ok, Path.t()} | {:error, term()}
  def setup_controller(dolphin_home, port, type \\ :standard) when port in 1..4 do
    pipe = pipes_path(dolphin_home, port)

    with :ok <- ensure_fifo(pipe, type),
         :ok <- write_gcpad_config(dolphin_home, port, type),
         :ok <- write_sidevice(dolphin_home, port, type) do
      {:ok, pipe}
    end
  end

  defp ensure_fifo(pipe, :standard) do
    File.mkdir_p!(Path.dirname(pipe))

    if File.exists?(pipe) do
      :ok
    else
      case System.cmd("mkfifo", [pipe], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> {:error, {:mkfifo_failed, String.trim(out)}}
      end
    end
  end

  defp ensure_fifo(_pipe, _type), do: :ok

  defp write_gcpad_config(dolphin_home, port, type) do
    path = Path.join([dolphin_home, "Config", "GCPadNew.ini"])
    section = "GCPad#{port}"

    entries =
      case type do
        :standard -> standard_pad_entries(port)
        _ -> [{"Device", "XInput2/0/Virtual core pointer"}]
      end

    update_ini(path, section, entries)
  end

  defp write_sidevice(dolphin_home, port, type) do
    path = Path.join([dolphin_home, "Config", "Dolphin.ini"])
    update_ini(path, "Core", [{"SIDevice#{port - 1}", Map.fetch!(@sidevice, type)}])
  end

  # The exact pad mapping libmelee writes (console.py setup_dolphin_controller).
  defp standard_pad_entries(port) do
    [
      {"Device", "Pipe/0/slippibot#{port}"},
      {"Buttons/A", "Button A"},
      {"Buttons/B", "Button B"},
      {"Buttons/X", "Button X"},
      {"Buttons/Y", "Button Y"},
      {"Buttons/Z", "Button Z"},
      {"Buttons/L", "Button L"},
      {"Buttons/R", "Button R"},
      {"Buttons/Threshold", "50"},
      {"Main Stick/Up", "Axis MAIN Y +"},
      {"Main Stick/Down", "Axis MAIN Y -"},
      {"Main Stick/Left", "Axis MAIN X -"},
      {"Main Stick/Right", "Axis MAIN X +"},
      {"Triggers/L", "Button L"},
      {"Triggers/R", "Button R"},
      {"Main Stick/Radius", "100"},
      {"D-Pad/Up", "Button D_UP"},
      {"D-Pad/Down", "Button D_DOWN"},
      {"D-Pad/Left", "Button D_LEFT"},
      {"D-Pad/Right", "Button D_RIGHT"},
      {"Buttons/Start", "Button START"},
      {"C-Stick/Up", "Axis C Y +"},
      {"C-Stick/Down", "Axis C Y -"},
      {"C-Stick/Left", "Axis C X -"},
      {"C-Stick/Right", "Axis C X +"},
      {"C-Stick/Radius", "100"},
      {"Triggers/L-Analog", "Axis L +"},
      {"Triggers/R-Analog", "Axis R +"},
      # Applies to digital presses; 100 would break them (strict compare).
      {"Triggers/Threshold", "90"}
    ]
  end

  ## Minimal INI read-modify-write that preserves unrelated sections.

  defp update_ini(path, section, entries) do
    File.mkdir_p!(Path.dirname(path))

    sections =
      if File.exists?(path) do
        parse_ini(File.read!(path))
      else
        []
      end

    sections =
      case List.keyfind(sections, section, 0) do
        nil ->
          sections ++ [{section, entries}]

        {^section, existing} ->
          merged =
            Enum.reduce(entries, existing, fn {k, v}, acc ->
              List.keystore(acc, k, 0, {k, v})
            end)

          List.keyreplace(sections, section, 0, {section, merged})
      end

    File.write(path, render_ini(sections))
  end

  defp parse_ini(content) do
    content
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce([], fn line, acc ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" or String.starts_with?(trimmed, ["#", ";"]) ->
          acc

        String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") ->
          [{String.slice(trimmed, 1..-2//1), []} | acc]

        acc == [] ->
          acc

        true ->
          case String.split(trimmed, "=", parts: 2) do
            [key, value] ->
              [{section, entries} | rest] = acc
              [{section, entries ++ [{String.trim(key), String.trim(value)}]} | rest]

            _ ->
              acc
          end
      end
    end)
    |> Enum.reverse()
  end

  defp render_ini(sections) do
    Enum.map_join(sections, "\n", fn {section, entries} ->
      "[#{section}]\n" <> Enum.map_join(entries, "\n", fn {k, v} -> "#{k} = #{v}" end) <> "\n"
    end)
  end
end
