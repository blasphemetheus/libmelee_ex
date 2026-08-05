defmodule Melee.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/blasphemetheus/libmelee_ex"

  def project do
    [
      app: :libmelee_ex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Elixir port of libmelee: an API for making Super Smash Bros. Melee AIs
    that work with Slippi Online. Tracks vladfi1's libmelee fork semantics.
    """
  end

  defp package do
    [
      licenses: ["LGPL-3.0-only"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Melee",
      source_url: @source_url
    ]
  end
end
