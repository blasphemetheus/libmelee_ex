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
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :jason],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
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

  # `Melee.Probe` (test/support) is live-Dolphin exploration tooling, so
  # it is compiled for tests only and stays out of the published package.
  # Drive exploration scripts with `MIX_ENV=test mix run script.exs`.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:rustler, "~> 0.36", runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
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
      source_url: @source_url,
      extras: [
        "README.md",
        "docs/getting-started.md",
        "docs/melee-menus.md",
        "docs/behavior-testing.md"
      ],
      groups_for_extras: [
        Guides: [
          "docs/getting-started.md",
          "docs/melee-menus.md",
          "docs/behavior-testing.md"
        ]
      ]
    ]
  end
end
