defmodule Ruxi.ProductionJobs do
  alias Ruxi.{DB, Util, Objects}

  @outputs %{
    "video" => {"video/mp4", "mp4", 524_288_000},
    "poster" => {"image/jpeg", "jpg", 4_194_304},
    "subtitle" => {"text/vtt", "vtt", 1_048_576},
    "proposal" => {"application/json", "json", 65_536}
  }
  def lease!(id, p, principal, lock \\ false) do
    job =
      DB.one("SELECT * FROM work_items WHERE id=$1" <> if(lock, do: " FOR UPDATE", else: ""), [
        DB.uuid(id)
      ])

    Util.require!(job != nil, "RESOURCE_NOT_FOUND")

    Util.require!(
      job["leased_by"] == principal["worker_id"] and job["kind"] in principal["allowed_kinds"],
      "NOT_ALLOWED"
    )

    Util.require!(
      job["status"] == "leased" and job["attempt"] == p["attempt"] and
        job["lease_hash"] == Util.hash(p["lease_token"] || "") and job["lease_until"] > DB.time(),
      "STALE_LEASE"
    )

    job
  end

  def source(conn, id, p, principal) do
    job = lease!(id, p, principal)
    Util.require!(job["kind"] == "media_transcode", "NOT_ALLOWED")
    asset = DB.one("SELECT * FROM assets WHERE id=$1", [DB.uuid(job["basis"]["asset_id"])])
    Util.require!(asset["status"] == "processing", "NOT_ALLOWED")
    file = Objects.verify!(asset["object_key"], asset["size_bytes"], asset["sha256"])

    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_resp_content_type("application/octet-stream")
    |> Plug.Conn.send_file(200, file)
  end

  def output_intents(id, p, principal, origin) do
    RuxiWeb.Router.json!(p, ~w(attempt lease_token outputs))
    job = lease!(id, p, principal)
    Util.require!(job["kind"] in ~w(editor_ai media_transcode), "NOT_ALLOWED")
    kinds = if job["kind"] == "editor_ai", do: ["proposal"], else: ~w(video poster subtitle)

    Util.require!(
      is_list(p["outputs"]) and length(p["outputs"]) == length(kinds) and
        Enum.sort(Enum.map(p["outputs"], & &1["kind"])) == Enum.sort(kinds),
      "INVALID_ARGUMENT"
    )

    %{
      "items" =>
        Enum.map(p["outputs"], fn output ->
          RuxiWeb.Router.json!(output, ~w(kind size_bytes sha256))
          {mime, ext, max} = @outputs[output["kind"]]

          Util.require!(
            is_integer(output["size_bytes"]) and output["size_bytes"] in 1..max and
              Ruxi.Assets.digest?(output["sha256"]),
            "INVALID_ARGUMENT"
          )

          key = "ruxi/jobs/#{id}/#{job["attempt"]}/#{output["kind"]}.#{ext}"

          cap =
            Map.merge(output, %{
              "scope" => "output",
              "job_id" => id,
              "attempt" => job["attempt"],
              "lease_hash" => job["lease_hash"],
              "mime_type" => mime,
              "object_key" => key
            })

          %{
            "kind" => output["kind"],
            "object_key" => key,
            "mime_type" => mime,
            "upload_url" =>
              origin <> "/api/uploads/" <> Phoenix.Token.sign(RuxiWeb.Endpoint, "upload", cap)
          }
        end)
    }
  end

  def dispatch(id, op, p, principal) do
    fields =
      ~w(attempt lease_token) ++
        case op do
          "complete" -> ~w(result_hash result)
          "fail" -> ~w(code retryable)
          _ -> []
        end

    RuxiWeb.Router.json!(p, fields)

    DB.transaction(fn ->
      meta = DB.one("SELECT kind,basis FROM work_items WHERE id=$1", [DB.uuid(id)])
      Util.require!(meta != nil, "RESOURCE_NOT_FOUND")

      subject =
        if meta["kind"] == "media_transcode",
          do:
            DB.one("SELECT * FROM assets WHERE id=$1 FOR UPDATE", [
              DB.uuid(meta["basis"]["asset_id"])
            ]),
          else:
            DB.one("SELECT * FROM content_versions WHERE id=$1 FOR UPDATE", [
              DB.uuid(meta["basis"]["version_id"])
            ])

      job = DB.one("SELECT * FROM work_items WHERE id=$1 FOR UPDATE", [DB.uuid(id)])

      Util.require!(
        job["leased_by"] == principal["worker_id"] and job["kind"] in principal["allowed_kinds"],
        "NOT_ALLOWED"
      )

      if op == "complete" and job["completed_attempt"] == p["attempt"] do
        Util.require!(job["lease_hash"] == Util.hash(p["lease_token"] || ""), "STALE_LEASE")
        Util.require!(job["result_hash"] == p["result_hash"], "RESULT_CONFLICT")
        job["completion_response_json"]
      else
        lease!(id, p, principal)

        case op do
          "heartbeat" ->
            DB.query("UPDATE work_items SET lease_until=$2 WHERE id=$1", [
              job["id"],
              DB.time() + 60_000
            ])

            %{"lease_until" => Util.iso(DB.time() + 60_000), "cancel_requested" => false}

          "fail" ->
            Util.require!(
              is_boolean(p["retryable"]) and is_binary(p["code"]) and
                String.length(p["code"]) in 1..64,
              "INVALID_ARGUMENT"
            )

            retry = p["retryable"] and job["attempt"] < 3

            DB.query("UPDATE work_items SET status=$2,lease_until=NULL WHERE id=$1", [
              job["id"],
              if(retry, do: "queued", else: "failed")
            ])

            if job["kind"] == "media_transcode" and not retry,
              do:
                DB.query("UPDATE assets SET status='quarantined',error_code=$2 WHERE id=$1", [
                  subject["id"],
                  p["code"]
                ])

            %{"status" => "failed"}

          "complete" ->
            Util.require!(p["result_hash"] == Util.hash(p["result"]), "RESULT_CONFLICT")
            reply = complete!(job, subject, p["result"])

            DB.query(
              "UPDATE work_items SET status='completed',result_hash=$2,result_json=$3,completion_response_json=$4,completed_attempt=$5 WHERE id=$1",
              [job["id"], p["result_hash"], p["result"], reply, p["attempt"]]
            )

            reply
        end
      end
    end)
  end

  defp complete!(%{"kind" => "media_transcode"} = job, asset, result) do
    RuxiWeb.Router.json!(result, ~w(outputs))

    Util.require!(
      is_list(result["outputs"]) and length(result["outputs"]) == 3,
      "INVALID_ARGUMENT"
    )

    outputs =
      Map.new(
        Enum.map(result["outputs"], fn o ->
          RuxiWeb.Router.json!(o, ~w(asset_id object_key sha256 mime_type size_bytes))

          {kind, descriptor} =
            Enum.find(@outputs, fn {_, {mime, _, _}} -> mime == o["mime_type"] end) || {nil, nil}

          Util.require!(kind in ~w(video poster subtitle), "INVALID_ARGUMENT")
          {_, ext, max} = descriptor

          Util.require!(
            o["asset_id"] == DB.str(asset["id"]) and
              o["object_key"] == "ruxi/jobs/#{DB.str(job["id"])}/#{job["attempt"]}/#{kind}.#{ext}" and
              is_integer(o["size_bytes"]) and o["size_bytes"] in 1..max and
              Ruxi.Assets.digest?(o["sha256"]),
            "INVALID_ARGUMENT"
          )

          Objects.verify!(o["object_key"], o["size_bytes"], o["sha256"])
          {kind, o}
        end)
      )

    Util.require!(Enum.sort(Map.keys(outputs)) == ~w(poster subtitle video), "INVALID_ARGUMENT")

    video =
      File.open!(Objects.path(outputs["video"]["object_key"]), [:read, :binary], fn f ->
        IO.binread(f, 16)
      end)

    poster =
      File.open!(Objects.path(outputs["poster"]["object_key"]), [:read, :binary], fn f ->
        IO.binread(f, 3)
      end)

    Util.require!(
      is_binary(video) and byte_size(video) >= 12 and binary_part(video, 4, 4) == "ftyp" and
        poster == <<255, 216, 255>>,
      "ASSET_MISMATCH"
    )

    vtt = File.read!(Objects.path(outputs["subtitle"]["object_key"]))
    # Worker emits trusted metadata as a WEBVTT NOTE, not arbitrary result fields.
    duration =
      case Regex.run(~r/\AWEBVTT\nNOTE duration_ms=(\d+)\n/, vtt) do
        [_, ms] -> String.to_integer(ms)
        _ -> Util.fail("ASSET_MISMATCH")
      end

    Util.require!(duration in 1000..900_000 and asset["status"] == "processing", "ASSET_MISMATCH")

    DB.query(
      "UPDATE assets SET status='ready',outputs=$2,duration_ms=$3,error_code=NULL WHERE id=$1",
      [asset["id"], outputs, duration]
    )

    %{"status" => "accepted"}
  end

  defp complete!(%{"kind" => "editor_ai"} = job, version, result),
    do: Ruxi.EditorAI.complete!(job, version, result)
end
