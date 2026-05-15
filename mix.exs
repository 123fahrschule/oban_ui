defmodule ObanUI.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/ariemer/oban_ui"

  def project do
    [
      app: :oban_ui,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      docs: docs(),
      description: "An open-source LiveView dashboard for Oban.",
      source_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: ["test.all": :test, dev: :dev]]
  end

  def application do
    [extra_applications: extra_applications(Mix.env())]
  end

  defp extra_applications(:dev), do: [:logger, :runtime_tools, :wx, :observer]
  defp extra_applications(_), do: [:logger]

  defp elixirc_paths(:test), do: ["lib", "test/support", "dev"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_html, "~> 4.0"},
      {:oban, "~> 2.18"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:plug_cowboy, "~> 2.5", only: [:dev, :test]},
      {:tailwind, "~> 0.2", only: :dev, runtime: false},
      {:esbuild, "~> 0.8", only: :dev, runtime: false},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      dev: "run --no-halt dev/dev.exs",
      "assets.build": ["tailwind oban_ui", "esbuild oban_ui"],
      "assets.deploy": [
        "tailwind oban_ui --minify",
        "esbuild oban_ui --minify",
        "phx.digest priv/static"
      ],
      "test.all": ["format --check-formatted", "test"]
    ]
  end

  defp package do
    [
      maintainers: ["A. Riemer"],
      licenses: ["MIT"],
      files: ~w(lib priv/static .formatter.exs mix.exs README.md LICENSE),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "ObanUI",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
