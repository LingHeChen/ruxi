defmodule Ruxi.CloudSQL do
  @moduledoc """
  Server-only HTTP SQL. Each request is one transaction. Never emulate transaction
  callbacks with separate requests; use atomic batches or database functions.
  """
  defmodule Error do
    defexception [:status, :code, message: "CloudBase database request failed"]
  end

  def execute!(sql, parameters \\ []) when is_binary(sql) and is_list(parameters) do
    unless Enum.all?(parameters, &scalar?/1),
      do: raise(ArgumentError, "SQL parameters must be JSON scalars; encode JSON explicitly")

    payload = Jason.encode!(%{sql: sql, parameters: parameters, role: "cloudbase_postgres"})
    transport = Application.get_env(:ruxi, :cloud_sql_transport, &http_request/1)
    started = System.monotonic_time(:microsecond)

    {status, bytes} =
      try do
        transport.(payload)
      after
        metrics = metrics()

        Process.put({__MODULE__, :metrics}, %{
          calls: metrics.calls + 1,
          microseconds: metrics.microseconds + System.monotonic_time(:microsecond) - started
        })
      end

    case {status, Jason.decode(bytes)} do
      {200, {:ok, rows}} when is_list(rows) ->
        rows

      {_, {:ok, data}} when is_map(data) ->
        code = data["code"] || if is_map(data["error"]), do: data["error"]["code"]
        code = if is_binary(code) and Regex.match?(~r/\A[A-Z0-9_]{1,80}\z/, code), do: code
        raise Error, status: status, code: code

      _ ->
        raise Error, status: status
    end
  end

  def reset_metrics, do: Process.put({__MODULE__, :metrics}, %{calls: 0, microseconds: 0})
  def metrics, do: Process.get({__MODULE__, :metrics}, %{calls: 0, microseconds: 0})

  def batch!(statements) when is_list(statements) do
    unless length(statements) <= 256 and
             Enum.all?(statements, fn
               %{"sql" => sql, "mode" => mode} when is_binary(sql) -> mode in ["rows", "command"]
               _ -> false
             end),
           do: raise(ArgumentError, "invalid atomic SQL batch")

    case execute!("SELECT ruxi.http_batch($1::jsonb) AS result", [Jason.encode!(statements)]) do
      [%{"result" => result}] when is_list(result) -> result
      _ -> raise Error, status: 200
    end
  end

  defp scalar?(v),
    do: is_nil(v) or is_boolean(v) or is_number(v) or (is_binary(v) and String.valid?(v))

  defp http_request(payload) do
    env = System.fetch_env!("CLOUDBASE_ENV_ID")

    unless Regex.match?(~r/\A[a-z0-9-]+\z/, env),
      do: raise(ArgumentError, "invalid environment ID")

    host = env <> ".api.tcloudbasegateway.com"
    url = String.to_charlist("https://" <> host <> "/v1/rdb/exec-pgsql")

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> System.fetch_env!("CLOUDBASE_API_KEY"))}
    ]

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    # A timeout may follow a commit. Never automatically retry writes.
    case :httpc.request(
           :post,
           {url, headers, ~c"application/json", payload},
           [timeout: 30_000, connect_timeout: 10_000, autoredirect: false, ssl: ssl],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, bytes}} -> {status, bytes}
      _ -> raise Error, code: "DATABASE_UNAVAILABLE"
    end
  end
end
