defmodule Ruxi.Release do
  @moduledoc "Explicit database migrations for the production OTP release."

  @app :ruxi

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Adapters.SQL.query!(repo, "CREATE SCHEMA IF NOT EXISTS ruxi", [])
          Ecto.Adapters.SQL.query!(repo, "REVOKE ALL ON SCHEMA ruxi FROM PUBLIC", [])
          Ecto.Migrator.run(repo, :up, all: true, prefix: "ruxi")
        end)
    end
  end
end
