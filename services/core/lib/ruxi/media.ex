defmodule Ruxi.Media do
  alias Ruxi.{DB, Util, Auth, Store, Content, Rules}
  def root, do: System.get_env("MEDIA_ROOT", Path.expand("../../content/demo/media", File.cwd!()))

  def manifest do
    case File.read(Path.join(root(), "manifest.json")) do
      {:ok, data} -> Jason.decode!(data)
      _ -> []
    end
  end

  def ready?, do: ready?(Content.demo_graph())
  def lookup(id), do: Enum.find(manifest(), &(&1["asset_id"] == id)) || Ruxi.Assets.lookup(id)

  def file(asset, kind) do
    key =
      case kind do
        "subtitle" -> asset["subtitle_file"]
        "poster" -> asset["poster_file"]
        _ -> asset["file"]
      end

    if asset["object_store"], do: Ruxi.Objects.path(key), else: Path.join(root(), key)
  end

  def ready?(g) do
    assets = if is_map(g), do: g["assets"], else: nil

    is_list(assets) and assets != [] and
      Enum.all?(assets, fn declared ->
        asset = lookup(declared["asset_id"])

        if asset && asset["sha256"] == declared["sha256"] do
          path = file(asset, "video")

          File.regular?(path) and Ruxi.Objects.hash(path) == asset["sha256"] and
            asset["duration_ms"] == declared["duration_ms"] and
            (asset["object_store"] != true or
               (asset["source"] == declared["source"] and File.regular?(file(asset, "poster")) and
                  File.regular?(file(asset, "subtitle"))))
        else
          false
        end
      end)
  rescue
    _ -> false
  end

  def access(ctx, p, origin) do
    DB.transaction(fn ->
      c = Auth.member_context(ctx, p["room_id"], p["device_id"], p["control_generation"])
      s = Store.load!(c.room, true)["state_json"]
      Store.auth!(s, c)

      v =
        DB.one("SELECT availability,graph FROM content_versions WHERE id=$1", [
          DB.uuid(s["content_version_id"])
        ])

      Util.require!(v["availability"] != "blocked", "CONTENT_BLOCKED")

      media =
        Enum.find(
          Rules.project(s, c.member)["media"]["authorized"],
          &(&1["asset_id"] == p["asset_id"])
        )

      Util.require!(media != nil, "RESOURCE_NOT_FOUND")

      asset = lookup(p["asset_id"])

      declared = Enum.find(v["graph"]["assets"] || [], &(&1["asset_id"] == p["asset_id"]))

      summary =
        if declared,
          do: declared["summary"],
          else: Content.summary(media["media_id"], Rules.member(s, c.member)["role"])

      if asset do
        declared = Enum.find(v["graph"]["assets"] || [], &(&1["asset_id"] == asset["asset_id"]))
        Util.require!(declared && declared["sha256"] == asset["sha256"], "RESOURCE_NOT_FOUND")
        summary = asset["summary"] || summary

        cap = %{
          "asset_id" => asset["asset_id"],
          "version_id" => s["content_version_id"],
          "sha256" => asset["sha256"]
        }

        video = Phoenix.Token.sign(RuxiWeb.Endpoint, "media", Map.put(cap, "kind", "video"))
        subtitle = Phoenix.Token.sign(RuxiWeb.Endpoint, "media", Map.put(cap, "kind", "subtitle"))

        %{
          "url" => origin <> "/api/media/" <> video,
          "expires_at" => Util.iso(DB.time() + 120_000),
          "mime_type" => "video/mp4",
          "duration_ms" => asset["duration_ms"],
          "subtitle" => %{"url" => origin <> "/api/media/" <> subtitle, "language" => "zh-CN"},
          "summary" => summary,
          "asset_status" =>
            if(asset["object_store"], do: "ready", else: "programmatic_demo_ready")
        }
      else
        %{
          "url" => nil,
          "expires_at" => Util.iso(DB.time() + 120_000),
          "mime_type" => "text/plain",
          "duration_ms" => 0,
          "summary" => summary,
          "asset_status" => "missing_original_video"
        }
      end
    end)
  end

  def stream(conn, token) do
    import Plug.Conn

    case Phoenix.Token.verify(RuxiWeb.Endpoint, "media", token, max_age: 120) do
      {:ok, cap} ->
        version =
          DB.one("SELECT availability,graph FROM content_versions WHERE id=$1", [
            DB.uuid(cap["version_id"])
          ])

        asset = lookup(cap["asset_id"])

        Util.require!(
          version != nil and version["availability"] != "blocked" and asset != nil,
          "RESOURCE_NOT_FOUND"
        )

        Util.require!(
          cap["sha256"] == asset["sha256"] and
            Enum.any?(
              version["graph"]["assets"] || [],
              &(&1["asset_id"] == cap["asset_id"] and &1["sha256"] == cap["sha256"])
            ),
          "RESOURCE_NOT_FOUND"
        )

        file = file(asset, cap["kind"])

        size = File.stat!(file).size

        conn =
          conn
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_content_type(
            if(cap["kind"] == "subtitle", do: "text/vtt", else: "video/mp4")
          )

        case get_req_header(conn, "range") do
          [] ->
            send_file(conn, 200, file)

          [range] ->
            case Regex.run(~r/^bytes=(\d+)-(\d*)$/, range) do
              [_, first, last] ->
                start = String.to_integer(first)
                stop = if(last == "", do: size - 1, else: min(size - 1, String.to_integer(last)))

                if start < size and start <= stop do
                  conn
                  |> put_resp_header("content-range", "bytes #{start}-#{stop}/#{size}")
                  |> send_file(206, file, start, stop - start + 1)
                else
                  conn
                  |> put_resp_header("content-range", "bytes */#{size}")
                  |> send_resp(416, "")
                end

              _ ->
                conn |> put_resp_header("content-range", "bytes */#{size}") |> send_resp(416, "")
            end
        end

      _ ->
        conn |> put_resp_header("cache-control", "no-store") |> send_resp(403, "")
    end
  end
end
