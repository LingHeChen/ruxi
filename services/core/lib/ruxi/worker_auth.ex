defmodule Ruxi.WorkerAuth do
  alias Ruxi.Util
  @kinds ~w(player_hint editor_ai media_transcode)
  def configured do
    case System.get_env("WORKER_CREDENTIALS_JSON") do
      nil ->
        [
          %{
            "worker_id" => "local-hint-worker",
            "token" => Application.fetch_env!(:ruxi, :worker_token),
            "allowed_kinds" => ["player_hint", "editor_ai", "media_transcode"]
          }
        ]

      value ->
        Jason.decode!(value)
    end
  end

  def authenticate(token, credentials \\ configured()) do
    hash = Util.hash(token || "")

    credential =
      Enum.find(credentials, fn c ->
        is_binary(c["token"]) and Plug.Crypto.secure_compare(hash, Util.hash(c["token"]))
      end)

    Util.require!(credential != nil, "UNAUTHORIZED")

    Util.require!(
      is_binary(credential["worker_id"]) and credential["worker_id"] != "" and
        is_list(credential["allowed_kinds"]) and credential["allowed_kinds"] != [] and
        Enum.all?(credential["allowed_kinds"], &(&1 in @kinds)),
      "UNAUTHORIZED"
    )

    Map.take(credential, ~w(worker_id allowed_kinds))
  end
end
