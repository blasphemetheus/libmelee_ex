defmodule Melee.Dolphin.Version do
  @moduledoc """
  Ask a Dolphin executable what it is, by running `<exe> --version` and
  reading the exit status and output.

  Ports libmelee v0.47's `get_dolphin_version` / `DolphinVersion` /
  `DolphinBuild` (`console.py`), Linux branch. The three builds are told
  apart by *exit status*, because none of them agree on how to report a
  version:

  | status | stream | shape | result |
  |---|---|---|---|
  | `0` | stdout | `4.0.0-mainline-beta.19` | mainline, `:netplay` |
  | `0` | stdout | ... containing `ExiAI` | mainline, `:exi_ai` |
  | `255` | stdout | `3.6.4` | Ishiiruka, `:netplay` |
  | `1` | stderr | `Faster Melee - Slippi (3.5.1) - ExiAI` | Ishiiruka, `:exi_ai` |

  The `ExiAI`-in-the-mainline-output test is the v0.43→v0.47 delta: the
  fork's mainline branch now sets `build = EXI_AI if 'ExiAI' in output`.

  `:playback` exists in upstream's `DolphinBuild` enum but no Linux
  branch ever produces it, so neither does this port.
  """

  @enforce_keys [:version, :build, :mainline?]
  defstruct [:version, :build, :mainline?, :output]

  @typedoc "Which Dolphin build a binary is."
  @type build :: :netplay | :playback | :exi_ai

  @typedoc """
  The identity of a Dolphin binary.

    * `:version` — version string as reported (mainline reports its full
      `--version` line, Ishiiruka just the number)
    * `:build` — `:netplay`, `:playback` or `:exi_ai`
    * `:mainline?` — true for mainline, false for Ishiiruka
    * `:output` — the raw trimmed output the verdict was read from
  """
  @type t :: %__MODULE__{
          version: String.t(),
          build: build(),
          mainline?: boolean(),
          output: String.t()
        }

  @doc """
  Classify a `--version` run from its exit status, stdout and stderr.

  Pure — `Melee.Dolphin.version/1` runs the process and calls this. The
  worked examples are the three real builds on this machine.

  ## Examples

      iex> Melee.Dolphin.Version.classify(0, "4.0.0-mainline-beta.19\\n", "")
      {:ok, %Melee.Dolphin.Version{
        version: "4.0.0-mainline-beta.19",
        build: :netplay,
        mainline?: true,
        output: "4.0.0-mainline-beta.19"
      }}

      iex> {:ok, v} = Melee.Dolphin.Version.classify(0, "4.0.0-mainline-ExiAI.3", "")
      iex> {v.mainline?, v.build}
      {true, :exi_ai}

      iex> {:ok, v} = Melee.Dolphin.Version.classify(255, "3.6.4\\n", "gvfs noise")
      iex> {v.mainline?, v.build, v.version}
      {false, :netplay, "3.6.4"}

      iex> {:ok, v} = Melee.Dolphin.Version.classify(1, "", "Faster Melee - Slippi (3.5.1) - ExiAI")
      iex> {v.mainline?, v.build, v.version}
      {false, :exi_ai, "3.5.1"}

      iex> Melee.Dolphin.Version.classify(3, "", "boom")
      {:error, {:unexpected_exit_status, 3, "", "boom"}}
  """
  @spec classify(integer(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def classify(status, stdout, stderr)

  def classify(0, stdout, _stderr) do
    output = String.trim(stdout)
    build = if String.contains?(output, "ExiAI"), do: :exi_ai, else: :netplay
    {:ok, %__MODULE__{version: output, build: build, mainline?: true, output: output}}
  end

  # Ishiiruka netplay: nonzero status, but the version is still on stdout.
  def classify(255, stdout, _stderr) do
    output = String.trim(stdout)
    {:ok, %__MODULE__{version: output, build: :netplay, mainline?: false, output: output}}
  end

  # ExiAI Ishiiruka: "Faster Melee - Slippi (VERSION) - ExiAI" on stderr.
  def classify(1, _stdout, stderr) do
    output = String.trim(stderr)

    case String.split(output, " - ") do
      ["Faster Melee", slippi, "ExiAI" | _] ->
        {:ok,
         %__MODULE__{
           version: parenthesized(slippi),
           build: :exi_ai,
           mainline?: false,
           output: output
         }}

      _ ->
        {:error, {:unexpected_version_output, output}}
    end
  end

  def classify(status, stdout, stderr) do
    {:error, {:unexpected_exit_status, status, String.trim(stdout), String.trim(stderr)}}
  end

  @doc """
  Pull the version out of `Slippi (3.5.1)`, falling back to the whole
  string when there are no parentheses.

  ## Examples

      iex> Melee.Dolphin.Version.parenthesized("Slippi (3.5.1)")
      "3.5.1"

      iex> Melee.Dolphin.Version.parenthesized("Slippi")
      "Slippi"
  """
  @spec parenthesized(String.t()) :: String.t()
  def parenthesized(string) do
    case Regex.run(~r/\(([^)]*)\)/, string) do
      [_, inner] -> inner
      nil -> string
    end
  end
end
