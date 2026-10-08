import Config

if config_env() == :prod do
  required = fn key ->
    case System.get_env(key) do
      v when is_binary(v) and byte_size(v) > 0 -> v
      _ -> raise "missing required deployment setting: #{key}"
    end
  end

  secret = required.("SECRET_KEY_BASE")
  if byte_size(secret) < 64, do: raise("SECRET_KEY_BASE must contain at least 64 bytes")
  database = required.("DATABASE_URL")
  epoch = required.("RECOVERY_EPOCH")
  instance = required.("CORE_INSTANCE")
  ledger = required.("ERASURE_LEDGER_PATH")
  if Path.type(ledger) != :absolute, do: raise("ERASURE_LEDGER_PATH must be absolute")
  credentials = required.("WORKER_CREDENTIALS_JSON") |> Jason.decode!()

  unless is_list(credentials) and credentials != [] and
           Enum.all?(credentials, fn c ->
             is_binary(c["worker_id"]) and is_binary(c["token"]) and byte_size(c["token"]) >= 32 and
               is_list(c["allowed_kinds"]) and c["allowed_kinds"] != [] and
               Enum.all?(
                 c["allowed_kinds"],
                 &(&1 in ~w(player_hint editor_ai media_transcode media_first_frame))
               )
           end),
         do: raise("invalid WORKER_CREDENTIALS_JSON")

  origins = required.("ALLOWED_ORIGINS") |> String.split(",", trim: true)

  unless origins != [] and
           Enum.all?(origins, fn origin ->
             uri = URI.parse(origin)

             uri.scheme == "https" and is_binary(uri.host) and uri.userinfo == nil and
               uri.query == nil and uri.fragment == nil and uri.path in [nil, "", "/"]
           end),
         do: raise("ALLOWED_ORIGINS must contain HTTPS origins")

  public = required.("PUBLIC_API_URL") |> URI.parse()

  unless public.scheme == "https" and public.host != nil and public.userinfo == nil and
           public.query == nil and public.fragment == nil and public.path in [nil, "", "/"],
         do: raise("PUBLIC_API_URL must be an HTTPS address")

  config :ruxi, recovery_epoch: epoch, core_instance: instance, allowed_origins: origins

  config :ruxi, Ruxi.Repo,
    url: database,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :ruxi, RuxiWeb.Endpoint,
    server: System.get_env("PHX_SERVER", "true") == "true",
    secret_key_base: secret,
    url: [host: public.host, scheme: "https", port: public.port || 443],
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    check_origin: origins
end
