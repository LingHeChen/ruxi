defmodule Ruxi.Assets do
  alias Ruxi.{DB, Util, Auth, Objects}
  @mimes ~w(video/mp4 video/webm video/quicktime)
  def intent(ctx, p, origin) do
    RuxiWeb.Router.json!(p, ~w(filename mime_type size_bytes sha256 command_id))
    Auth.role!(ctx, "editor")

    Util.require!(
      is_binary(p["filename"]) and String.length(p["filename"]) in 1..180 and
        p["mime_type"] in @mimes and
        is_integer(p["size_bytes"]) and p["size_bytes"] in 1..524_288_000 and digest?(p["sha256"]),
      "INVALID_ARGUMENT"
    )

    Auth.account(ctx, "asset.intent", p, fn ->
      id = Util.id()
      key = "ruxi/assets/#{id}/source.bin"
      now = DB.time()

      DB.query(
        "INSERT INTO assets(id,created_by,filename,mime_type,size_bytes,sha256,object_key,status,upload_expires_at,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,'uploading',$8,$9)",
        [
          DB.uuid(id),
          DB.uuid(ctx.user),
          p["filename"],
          p["mime_type"],
          p["size_bytes"],
          p["sha256"],
          key,
          now + 900_000,
          now
        ]
      )

      cap =
        Map.merge(Map.take(p, ~w(mime_type size_bytes sha256)), %{
          "scope" => "source",
          "asset_id" => id,
          "object_key" => key
        })

      %{
        "asset_id" => id,
        "upload_url" =>
          origin <> "/uploads/" <> Phoenix.Token.sign(RuxiWeb.Endpoint, "upload", cap),
        "headers" => %{"Content-Type" => p["mime_type"]},
        "expires_at" => Util.iso(now + 900_000)
      }
    end)
  end

  def complete(ctx, id, p) do
    RuxiWeb.Router.json!(p, ~w(sha256 size_bytes command_id), ~w(rights_source))
    Auth.role!(ctx, "editor")

    Auth.account(ctx, "asset.complete", Map.put(p, "asset_id", id), fn ->
      asset = DB.one("SELECT * FROM assets WHERE id=$1 FOR UPDATE", [DB.uuid(id)])
      Util.require!(asset != nil and DB.str(asset["created_by"]) == ctx.user, "NOT_ALLOWED")

      Util.require!(
        asset["sha256"] == p["sha256"] and asset["size_bytes"] == p["size_bytes"],
        "ASSET_MISMATCH"
      )

      Objects.verify!(asset["object_key"], p["size_bytes"], p["sha256"])
      source = p["rights_source"] || asset["rights_source"]

      Util.require!(
        is_binary(source) and String.length(String.trim(source)) in 1..2000,
        "RIGHTS_REQUIRED"
      )

      existing =
        DB.one(
          "SELECT id,status FROM work_items WHERE kind='media_transcode' AND basis->>'asset_id'=$1 ORDER BY created_at DESC LIMIT 1",
          [id]
        )

      if existing do
        %{"status" => asset["status"], "job_id" => DB.str(existing["id"])}
      else
        Util.require!(
          asset["status"] in ~w(uploading uploaded) and asset["upload_expires_at"] > DB.time(),
          "NOT_ALLOWED"
        )

        job = Util.id()

        input =
          Map.take(p, ~w(sha256 size_bytes))
          |> Map.put("asset_id", id)
          |> Map.put("mime_type", asset["mime_type"])

        DB.query("UPDATE assets SET status='processing',rights_source=$2 WHERE id=$1", [
          asset["id"],
          String.trim(source)
        ])

        DB.query(
          "INSERT INTO work_items(id,created_by,kind,input_json,basis,status,created_at) VALUES($1,$2,'media_transcode',$3,$4,'queued',$5)",
          [
            DB.uuid(job),
            DB.uuid(ctx.user),
            input,
            %{"asset_id" => id, "source_sha256" => p["sha256"]},
            DB.time()
          ]
        )

        %{"status" => "processing", "job_id" => job}
      end
    end)
  end

  def list(ctx) do
    Auth.role!(ctx, "editor")

    %{
      "items" =>
        DB.rows(
          "SELECT id,filename,status,duration_ms,outputs,error_code,rights_source FROM assets WHERE created_by=$1 ORDER BY created_at DESC LIMIT 100",
          [DB.uuid(ctx.user)]
        )
        |> Enum.map(fn row ->
          row |> Map.put("asset_id", DB.str(row["id"])) |> Map.delete("id")
        end)
    }
  end

  def captions(ctx, id, p) do
    RuxiWeb.Router.json!(p, ~w(command_id vtt))
    Auth.role!(ctx, "editor")
    Util.require!(is_binary(p["vtt"]) and byte_size(p["vtt"]) <= 60_000, "INVALID_ARGUMENT")

    Auth.account(ctx, "asset.captions", Map.put(p, "asset_id", id), fn ->
      asset =
        DB.one(
          "SELECT * FROM assets WHERE id=$1 AND created_by=$2 AND status='ready' FOR UPDATE",
          [DB.uuid(id), DB.uuid(ctx.user)]
        )

      Util.require!(asset != nil, "NOT_ALLOWED")
      text = String.replace(p["vtt"], "\r\n", "\n")
      blocks = String.split(String.trim(text), "\n\n", trim: true)

      Util.require!(
        List.first(blocks) == "WEBVTT" and length(blocks) in 2..201,
        "INVALID_CAPTIONS"
      )

      Enum.reduce(tl(blocks), 0, fn block, previous ->
        lines = String.split(block, "\n")
        lines = if String.contains?(hd(lines), " --> "), do: lines, else: tl(lines)
        Util.require!(length(lines) >= 2, "INVALID_CAPTIONS")
        [timing | body] = lines

        times =
          Regex.run(
            ~r/\A((?:\d{2}:)?[0-5]\d:[0-5]\d\.\d{3}) --> ((?:\d{2}:)?[0-5]\d:[0-5]\d\.\d{3})\z/,
            timing
          )

        Util.require!(times != nil, "INVALID_CAPTIONS")
        [_, first, last] = times
        start = caption_time(first)
        stop = caption_time(last)
        narrative = Enum.join(body, "\n")

        Util.require!(
          start >= previous and stop > start and stop <= asset["duration_ms"] and
            String.length(narrative) in 1..500 and
            not Regex.match?(~r/[<>\x00-\x08\x0B\x0C\x0E-\x1F]/u, narrative),
          "INVALID_CAPTIONS"
        )

        stop
      end)

      # A new immutable asset identity keeps existing published subtitles frozen.
      next = Util.id()
      key = "ruxi/assets/#{next}/captions.vtt"
      data = String.trim(text) <> "\n"
      Objects.put!(key, data, Util.hash(data))
      source = "ruxi/assets/#{next}/source.bin"
      File.ln!(Objects.path(asset["object_key"]), Objects.path(source))

      outputs =
        Map.put(asset["outputs"], "subtitle", %{
          "asset_id" => next,
          "object_key" => key,
          "mime_type" => "text/vtt",
          "size_bytes" => byte_size(data),
          "sha256" => Util.hash(data)
        })

      DB.query(
        "INSERT INTO assets(id,created_by,filename,mime_type,size_bytes,sha256,object_key,status,upload_expires_at,created_at,duration_ms,outputs,rights_source) VALUES($1,$2,$3,$4,$5,$6,$7,'ready',$8,$8,$9,$10,$11)",
        [
          DB.uuid(next),
          DB.uuid(ctx.user),
          asset["filename"] <> " · 字幕修订",
          asset["mime_type"],
          asset["size_bytes"],
          asset["sha256"],
          source,
          DB.time(),
          asset["duration_ms"],
          outputs,
          asset["rights_source"]
        ]
      )

      %{"asset_id" => next, "status" => "ready"}
    end)
  end

  defp caption_time(value) do
    [whole, milliseconds] = String.split(value, ".")

    seconds =
      whole
      |> String.split(":")
      |> Enum.reduce(0, fn n, sum -> sum * 60 + String.to_integer(n) end)

    seconds * 1000 + String.to_integer(milliseconds)
  end

  def preview(ctx, id, origin) do
    Auth.role!(ctx, "editor")

    row =
      DB.one("SELECT * FROM assets WHERE id=$1 AND created_by=$2 AND status='ready'", [
        DB.uuid(id),
        DB.uuid(ctx.user)
      ])

    Util.require!(row != nil, "NOT_ALLOWED")

    token =
      Phoenix.Token.sign(RuxiWeb.Endpoint, "asset-preview", %{
        "asset_id" => id,
        "user" => ctx.user,
        "session" => ctx.session,
        "sha256" => row["outputs"]["poster"]["sha256"]
      })

    %{"poster_url" => origin <> "/asset-preview/" <> token, "expires_in" => 60}
  end

  def poster(conn, token) do
    import Plug.Conn

    cap =
      case Phoenix.Token.verify(RuxiWeb.Endpoint, "asset-preview", token, max_age: 60) do
        {:ok, cap} -> cap
        _ -> Util.fail("NOT_ALLOWED")
      end

    ctx = %{user: cap["user"], session: cap["session"]}
    Auth.valid!(ctx)
    Auth.role!(ctx, "editor")

    row =
      DB.one("SELECT * FROM assets WHERE id=$1 AND created_by=$2 AND status='ready'", [
        DB.uuid(cap["asset_id"]),
        DB.uuid(cap["user"])
      ])

    Util.require!(
      row != nil and row["outputs"]["poster"]["sha256"] == cap["sha256"],
      "NOT_ALLOWED"
    )

    file =
      Objects.verify!(
        row["outputs"]["poster"]["object_key"],
        row["outputs"]["poster"]["size_bytes"],
        cap["sha256"]
      )

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("image/jpeg")
    |> send_file(200, file)
  end

  def lookup(id) do
    case DB.one("SELECT * FROM assets WHERE id=$1 AND status='ready'", [DB.uuid(id)]) do
      nil ->
        nil

      row ->
        outputs = row["outputs"]

        %{
          "asset_id" => id,
          "sha256" => outputs["video"]["sha256"],
          "file" => outputs["video"]["object_key"],
          "poster_file" => outputs["poster"]["object_key"],
          "subtitle_file" => outputs["subtitle"]["object_key"],
          "duration_ms" => row["duration_ms"],
          "source" => row["rights_source"],
          "object_store" => true
        }
    end
  end

  def digest?(v), do: is_binary(v) and Regex.match?(~r/\A[0-9a-f]{64}\z/, v)
end
