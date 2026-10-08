import Config

config :ruxi,
  ecto_repos: [Ruxi.Repo],
  recovery_epoch: System.get_env("RECOVERY_EPOCH", "local-C1"),
  worker_token: System.get_env("WORKER_TOKEN", "local-worker-change-me")

config :ruxi, Ruxi.Repo,
  url: System.get_env("DATABASE_URL", "postgres://localhost:55432/ruxi_dev"),
  parameters: [search_path: "ruxi,pg_catalog"],
  migration_default_prefix: "ruxi",
  pool_size: 10

config :ruxi, RuxiWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  server: System.get_env("PHX_SERVER", "false") == "true",
  url: [host: "localhost"],
  secret_key_base: System.get_env("SECRET_KEY_BASE", String.duplicate("development-only-", 5)),
  pubsub_server: Ruxi.PubSub,
  check_origin: ["//localhost:8080", "//127.0.0.1:8080", "//localhost:8081"]

config :phoenix, :json_library, Jason
config :logger, level: :warning

if config_env() == :test do
  config :ruxi, Ruxi.Repo,
    url: System.get_env("TEST_DATABASE_URL", "postgres://localhost:55432/ruxi_test"),
    pool: Ecto.Adapters.SQL.Sandbox

  config :ruxi, RuxiWeb.Endpoint, server: false
end
