defmodule Ruxi.Uploads do
  @moduledoc "Signed bounded raw uploads, before the JSON parser; never accepts a client path."
  import Plug.Conn
  alias Ruxi.{DB, Util, Objects}
  def init(options), do: options

  def call(%Plug.Conn{method: "PUT", path_info: ["api", "uploads", token]} = conn, _) do
    try do
      cap =
        case Phoenix.Token.verify(RuxiWeb.Endpoint, "upload", token, max_age: 900) do
          {:ok, cap} -> cap
          _ -> Util.fail("NOT_ALLOWED")
        end

      authorize!(cap)
      Util.require!(get_req_header(conn, "content-type") == [cap["mime_type"]], "ASSET_MISMATCH")
      target = Objects.path(cap["object_key"])
      File.mkdir_p!(Path.dirname(target))
      temp = target <> "." <> Util.id()

      try do
        {:ok, file} = File.open(temp, [:binary, :write, :exclusive])
        File.chmod!(temp, 0o600)

        conn =
          try do
            read!(conn, file, 0, cap["size_bytes"])
          after
            File.close(file)
          end

        authorize!(cap)
        Objects.commit!(temp, target, cap["size_bytes"], cap["sha256"])
        conn |> put_resp_header("cache-control", "no-store") |> send_resp(200, "") |> halt()
      after
        File.rm(temp)
      end
    catch
      {:error, code} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          if(code == "PAYLOAD_TOO_LARGE", do: 413, else: 403),
          Jason.encode!(%{"error" => Util.error(code)})
        )
        |> halt()
    end
  end

  def call(conn, _), do: conn

  defp read!(conn, file, count, limit) do
    case read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 30_000) do
      {status, body, conn} when status in [:more, :ok] ->
        Util.require!(count + byte_size(body) <= limit, "PAYLOAD_TOO_LARGE")
        IO.binwrite(file, body)
        if status == :more, do: read!(conn, file, count + byte_size(body), limit), else: conn

      _ ->
        Util.fail("SERVICE_UNAVAILABLE")
    end
  end

  defp authorize!(%{"scope" => "source"} = cap) do
    row =
      DB.one(
        "SELECT a.*,u.status AS user_status FROM assets a LEFT JOIN users u ON u.id=a.created_by WHERE a.id=$1",
        [DB.uuid(cap["asset_id"])]
      )

    Util.require!(
      row != nil and row["user_status"] == "active" and row["status"] in ~w(uploading uploaded) and
        row["upload_expires_at"] > DB.time() and row["sha256"] == cap["sha256"] and
        row["object_key"] == cap["object_key"],
      "NOT_ALLOWED"
    )
  end

  defp authorize!(%{"scope" => "output"} = cap) do
    job = DB.one("SELECT * FROM work_items WHERE id=$1", [DB.uuid(cap["job_id"])])

    Util.require!(
      job != nil and job["status"] == "leased" and job["attempt"] == cap["attempt"] and
        job["lease_hash"] == cap["lease_hash"] and job["lease_until"] > DB.time(),
      "STALE_LEASE"
    )
  end
end
