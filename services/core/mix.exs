defmodule Ruxi.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :ruxi,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [
        {:phoenix, "~> 1.8.0"},
        {:phoenix_ecto, "~> 4.7"},
        {:ecto_sql, "~> 3.13"},
        {:postgrex, "~> 0.21"},
        {:bandit, "~> 1.8"},
        {:jason, "~> 1.4"},
        {:oban, "~> 2.19.4"},
        {:cors_plug, "~> 3.0"}
      ],
      aliases: [
        setup: [
          "deps.get",
          "ecto.create",
          "run --no-start priv/repo/init_schema.exs",
          "ecto.migrate",
          "run priv/repo/seeds.exs"
        ]
      ]
    ]

  def application, do: [mod: {Ruxi.Application, []}, extra_applications: [:logger, :crypto, :inets, :ssl]]
end
