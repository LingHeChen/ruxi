defmodule Ruxi.CloudStorage do
  @moduledoc "Server-only CloudBase PG storage transport. Objects are never overwritten."
  alias Ruxi.Util

  def enabled?, do: System.get_env("OBJECT_BACKEND", "local") == "cloudbase"

  def get(key), do: request(:get, object_path(key))

  def put!(key, bytes) do
    Util.require!(byte_size(bytes) <= 268_435_456, "PAYLOAD_TOO_LARGE")

    case request(:post, object_path(key), bytes, "application/octet-stream") do
      {status, _} when status in 200..299 ->
        :ok

      {409, _} ->
        case get(key) do
          {200, ^bytes} -> :ok
          {200, _} -> Util.fail("ASSET_MISMATCH")
          _ -> Util.fail("SERVICE_UNAVAILABLE")
        end

      _ ->
        Util.fail("SERVICE_UNAVAILABLE")
    end
  end

  def delete!(key) do
    case request(:delete, object_path(key)) do
      {status, _} when status in 200..299 or status == 404 -> :ok
      _ -> Util.fail("SERVICE_UNAVAILABLE")
    end
  end

  def list!(prefix), do: list_page!(prefix, nil, MapSet.new(), [])

  defp list_page!(prefix, cursor, seen, acc) do
    body = %{"prefix" => prefix, "limit" => 1000, "with_delimiter" => false}
    body = if cursor, do: Map.put(body, "cursor", cursor), else: body

    case request(:post, "/object/list/" <> bucket(), Jason.encode!(body), "application/json") do
      {200, bytes} ->
        data = Jason.decode!(bytes)
        entries = Map.fetch!(data, "objects")
        keys = Enum.map(entries, &(&1["key"] || &1["name"]))

        Util.require!(
          Enum.all?(keys, &(is_binary(&1) and String.starts_with?(&1, prefix))),
          "SERVICE_UNAVAILABLE"
        )

        next = data["nextCursor"]

        Util.require!(
          data["hasNext"] != true or (is_binary(next) and next != ""),
          "SERVICE_UNAVAILABLE"
        )

        if next in [nil, ""] do
          Enum.reverse([keys | acc]) |> List.flatten()
        else
          Util.require!(is_binary(next) and not MapSet.member?(seen, next), "SERVICE_UNAVAILABLE")
          list_page!(prefix, next, MapSet.put(seen, next), [keys | acc])
        end

      _ ->
        Util.fail("SERVICE_UNAVAILABLE")
    end
  end

  defp object_path(key) do
    Util.require!(is_binary(key) and not String.contains?(key, ".."), "INVALID_ARGUMENT")
    "/object/" <> bucket() <> "/" <> URI.encode(key, &URI.char_unreserved?/1)
  end

  defp bucket do
    bucket = System.fetch_env!("CLOUDBASE_STORAGE_BUCKET")
    Util.require!(Regex.match?(~r/\A[a-z0-9-]+\z/, bucket), "INVALID_ARGUMENT")
    bucket
  end

  defp request(method, path, body \\ nil, content_type \\ nil) do
    case Application.get_env(:ruxi, :cloud_storage_transport) do
      nil -> http_request(method, path, body, content_type)
      transport -> transport.(method, path, body, content_type)
    end
  end

  defp http_request(method, path, body, content_type) do
    env = System.fetch_env!("CLOUDBASE_ENV_ID")
    Util.require!(Regex.match?(~r/\A[a-z0-9-]+\z/, env), "INVALID_ARGUMENT")
    host = env <> ".api.tcloudbasegateway.com"
    url = String.to_charlist("https://" <> host <> "/v1/storages" <> path)

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> System.fetch_env!("CLOUDBASE_API_KEY"))}
    ]

    req =
      if body == nil,
        do: {url, headers},
        else: {url, headers, String.to_charlist(content_type), body}

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(
           method,
           req,
           [timeout: 120_000, connect_timeout: 10_000, autoredirect: false, ssl: ssl],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, bytes}} -> {status, bytes}
      _ -> Util.fail("SERVICE_UNAVAILABLE")
    end
  end
end
