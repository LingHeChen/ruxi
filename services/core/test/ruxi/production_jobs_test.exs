defmodule Ruxi.ProductionJobsTest do
  use ExUnit.Case
  alias Ruxi.{Auth, DB, Util, Assets, Objects, Jobs, EditorAI, Admin}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    Ruxi.Content.seed()
    old = System.get_env("OBJECT_ROOT")
    root = Path.join(System.tmp_dir!(), "ruxi-objects-#{Util.id()}")
    System.put_env("OBJECT_ROOT", root)

    on_exit(fn ->
      File.rm_rf(root)
      if old, do: System.put_env("OBJECT_ROOT", old), else: System.delete_env("OBJECT_ROOT")
    end)

    {:ok, guest} = Auth.guest(%{"device_id" => Util.id(), "command_id" => Util.id()})
    user = guest["user_id"]

    for role <- ~w(editor reviewer publisher),
        do: DB.query("INSERT INTO admin_roles(user_id,role) VALUES($1,$2)", [DB.uuid(user), role])

    auth = Auth.session(user, Util.id(), "admin")

    %{
      ctx: Auth.authenticate(auth["access_token"], "admin"),
      principal: %{
        "worker_id" => "production-test",
        "allowed_kinds" => ~w(editor_ai media_transcode)
      }
    }
  end

  def claim(principal, kind) do
    {:ok, job} =
      Jobs.dispatch(
        ["claim"],
        %{
          "claim_id" => Util.id(),
          "worker_id" => principal["worker_id"],
          "supported_kinds" => [kind]
        },
        principal
      )

    job
  end

  def complete(principal, job, result),
    do:
      Jobs.dispatch(
        [job["job_id"], "complete"],
        %{
          "attempt" => job["attempt"],
          "lease_token" => job["lease_token"],
          "result" => result,
          "result_hash" => Util.hash(result)
        },
        principal
      )

  def draft(ctx) do
    {:ok, v} =
      Admin.dispatch(
        "POST",
        ["stories", Ruxi.Content.story_id(), "versions"],
        %{"command_id" => Util.id(), "base_version_id" => Ruxi.Content.version_id()},
        ctx
      )

    v["version_id"]
  end

  test "source hashes, rights and immutable upload paths gate processing", %{ctx: ctx} do
    bytes = "synthetic source"

    p = %{
      "filename" => "../source.mp4",
      "mime_type" => "video/mp4",
      "size_bytes" => byte_size(bytes),
      "sha256" => Util.hash(bytes),
      "command_id" => Util.id()
    }

    {:ok, intent} = Assets.intent(ctx, p, "https://example.test")
    {:ok, ^intent} = Assets.intent(ctx, p, "https://example.test")
    key = "ruxi/assets/#{intent["asset_id"]}/source.bin"
    Objects.put!(key, bytes, Util.hash(bytes))

    body = %{
      "command_id" => Util.id(),
      "sha256" => Util.hash(bytes),
      "size_bytes" => byte_size(bytes)
    }

    assert {:error, "RIGHTS_REQUIRED"} = Assets.complete(ctx, intent["asset_id"], body)

    assert {:ok, %{"status" => "processing"}} =
             Assets.complete(
               ctx,
               intent["asset_id"],
               Map.merge(body, %{"command_id" => Util.id(), "rights_source" => "原创测试素材"})
             )

    assert catch_throw(Objects.path("ruxi/assets/../escape.bin")) == {:error, "INVALID_ARGUMENT"}
  end

  test "editing proposals cannot mutate a draft before acceptance; acceptance invalidates approval",
       %{ctx: ctx, principal: principal} do
    id = draft(ctx)

    {:ok, _} =
      EditorAI.create(ctx, id, %{
        "command_id" => Util.id(),
        "revision" => 1,
        "target" => "title",
        "instruction" => "简洁"
      })

    job = claim(principal, "editor_ai")

    proposal = %{
      "schema_version" => 1,
      "target" => ["title"],
      "original" => job["input"]["original"],
      "suggested" => "最后一班车",
      "notes" => [],
      "source" => "ai"
    }

    data = Jason.encode!(proposal)
    key = "ruxi/jobs/#{job["job_id"]}/#{job["attempt"]}/proposal.json"
    Objects.put!(key, data, Util.hash(data))
    result = %{"proposal_ref" => key, "sha256" => Util.hash(data)}
    assert {:ok, %{"status" => "accepted"}} = complete(principal, job, result)
    assert {:ok, %{"status" => "accepted"}} = complete(principal, job, result)

    assert DB.one("SELECT graph FROM content_versions WHERE id=$1", [DB.uuid(id)])["graph"][
             "title"
           ] == proposal["original"]

    p = %{"command_id" => Util.id(), "revision" => 1}
    assert {:ok, %{"revision" => 2}} = EditorAI.apply(ctx, job["job_id"], p)
    assert {:ok, %{"revision" => 2}} = EditorAI.apply(ctx, job["job_id"], p)

    assert DB.one("SELECT status,approved_hash FROM content_versions WHERE id=$1", [DB.uuid(id)]) ==
             %{"status" => "draft", "approved_hash" => nil}
  end

  test "stale draft revisions and forged proposal targets are not applied", %{
    ctx: ctx,
    principal: principal
  } do
    id = draft(ctx)

    {:ok, _} =
      EditorAI.create(ctx, id, %{
        "command_id" => Util.id(),
        "revision" => 1,
        "target" => "title",
        "instruction" => "润色"
      })

    job = claim(principal, "editor_ai")

    proposal = %{
      "schema_version" => 1,
      "target" => ["decision"],
      "original" => job["input"]["original"],
      "suggested" => "拒绝",
      "notes" => [],
      "source" => "ai"
    }

    key = "ruxi/jobs/#{job["job_id"]}/1/proposal.json"
    data = Jason.encode!(proposal)
    Objects.put!(key, data, Util.hash(data))

    assert {:error, "INVALID_ARGUMENT"} =
             complete(principal, job, %{"proposal_ref" => key, "sha256" => Util.hash(data)})

    assert catch_throw(
             Ruxi.ProductionJobs.output_intents(
               job["job_id"],
               %{"attempt" => 1, "lease_token" => "forged", "outputs" => []},
               principal,
               "https://example.test"
             )
           ) == {:error, "STALE_LEASE"}
  end

  test "signed uploads enforce size, hashes, expiry and immutable object keys", %{ctx: ctx} do
    bytes = "bounded-upload"

    {:ok, intent} =
      Assets.intent(
        ctx,
        %{
          "command_id" => Util.id(),
          "filename" => "clip.mp4",
          "mime_type" => "video/mp4",
          "size_bytes" => byte_size(bytes),
          "sha256" => Util.hash(bytes)
        },
        "http://example.test"
      )

    path = URI.parse(intent["upload_url"]).path

    upload = fn body ->
      Plug.Test.conn(:put, path, body)
      |> Plug.Conn.put_req_header("content-type", "video/mp4")
      |> Ruxi.Uploads.call([])
    end

    assert upload.(bytes <> "extra").status == 413
    assert upload.(String.duplicate("x", byte_size(bytes))).status == 403
    assert upload.(bytes).status == 200
    assert upload.(bytes).status == 200
    DB.query("UPDATE assets SET upload_expires_at=0 WHERE id=$1", [DB.uuid(intent["asset_id"])])
    assert upload.(bytes).status == 403
  end

  test "expired production leases stop after three attempts", %{ctx: ctx, principal: principal} do
    id = draft(ctx)

    {:ok, created} =
      EditorAI.create(ctx, id, %{
        "command_id" => Util.id(),
        "revision" => 1,
        "target" => "title",
        "instruction" => "简洁"
      })

    job = claim(principal, "editor_ai")

    DB.query("UPDATE work_items SET attempt=3,lease_until=0 WHERE id=$1", [DB.uuid(job["job_id"])])

    assert {:ok, %{"expired_jobs" => 1}} = Ruxi.Maintenance.run()
    assert EditorAI.get(ctx, created["job_id"])["status"] == "failed"

    assert {:ok, %{"job_id" => nil}} =
             Jobs.dispatch(
               ["claim"],
               %{
                 "claim_id" => Util.id(),
                 "worker_id" => principal["worker_id"],
                 "supported_kinds" => ["editor_ai"]
               },
               principal
             )
  end

  test "valid proposals become inert when the author changes revision", %{
    ctx: ctx,
    principal: principal
  } do
    id = draft(ctx)

    {:ok, _} =
      EditorAI.create(ctx, id, %{
        "command_id" => Util.id(),
        "revision" => 1,
        "target" => "title",
        "instruction" => "简洁"
      })

    job = claim(principal, "editor_ai")
    graph = DB.one("SELECT graph FROM content_versions WHERE id=$1", [DB.uuid(id)])["graph"]

    assert {:ok, _} =
             Admin.dispatch(
               "PUT",
               ["versions", id],
               %{"revision" => 1, "graph" => Map.put(graph, "title", "人工修订")},
               ctx
             )

    proposal = %{
      "schema_version" => 1,
      "target" => ["title"],
      "original" => job["input"]["original"],
      "suggested" => "过期建议",
      "notes" => [],
      "source" => "ai"
    }

    data = Jason.encode!(proposal)
    key = "ruxi/jobs/#{job["job_id"]}/1/proposal.json"
    Objects.put!(key, data, Util.hash(data))

    assert {:ok, %{"status" => "ignored"}} =
             complete(principal, job, %{"proposal_ref" => key, "sha256" => Util.hash(data)})

    assert {:error, "NOT_ALLOWED"} =
             EditorAI.apply(ctx, job["job_id"], %{"command_id" => Util.id(), "revision" => 2})

    report = Ruxi.Operations.report(ctx)
    assert not String.contains?(Jason.encode!(report), ctx.user)
    assert Map.has_key?(report, "outcomes")
  end

  test "subtitle revisions preserve existing asset bytes and first-frame access is revocable", %{
    ctx: ctx
  } do
    source = "source-bytes"

    {:ok, intent} =
      Assets.intent(
        ctx,
        %{
          "command_id" => Util.id(),
          "filename" => "ready.mp4",
          "mime_type" => "video/mp4",
          "size_bytes" => byte_size(source),
          "sha256" => Util.hash(source)
        },
        "http://example.test"
      )

    id = intent["asset_id"]
    Objects.put!("ruxi/assets/#{id}/source.bin", source, Util.hash(source))

    outputs =
      Map.new(
        for {kind, suffix, mime, data} <- [
              {"video", "video.mp4", "video/mp4", source},
              {"poster", "poster.jpg", "image/jpeg", <<255, 216, 255, 1>>},
              {"subtitle", "subtitle.vtt", "text/vtt", "WEBVTT\n\n"}
            ] do
          key = "ruxi/assets/#{id}/#{suffix}"
          Objects.put!(key, data, Util.hash(data))

          {kind,
           %{
             "asset_id" => id,
             "object_key" => key,
             "sha256" => Util.hash(data),
             "size_bytes" => byte_size(data),
             "mime_type" => mime
           }}
        end
      )

    DB.query(
      "UPDATE assets SET status='ready',duration_ms=5000,outputs=$2,rights_source='原创' WHERE id=$1",
      [DB.uuid(id), outputs]
    )

    vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n中文字幕。\n"
    {:ok, next} = Assets.captions(ctx, id, %{"command_id" => Util.id(), "vtt" => vtt})
    assert next["asset_id"] != id
    assert File.read!(Objects.path(Assets.lookup(id)["subtitle_file"])) == "WEBVTT\n\n"
    assert File.read!(Objects.path(Assets.lookup(next["asset_id"])["subtitle_file"])) == vtt
    assert Assets.lookup(next["asset_id"])["sha256"] == outputs["video"]["sha256"]

    assert {:error, "INVALID_CAPTIONS"} =
             Assets.captions(ctx, id, %{
               "command_id" => Util.id(),
               "vtt" => String.replace(vtt, "00:00:01.000", "00:00:06.000")
             })

    assert {:error, "INVALID_CAPTIONS"} =
             Assets.captions(ctx, id, %{
               "command_id" => Util.id(),
               "vtt" => String.replace(vtt, "中文字幕。", "<script>bad</script>")
             })

    preview = Assets.preview(ctx, id, "http://example.test")
    token = URI.parse(preview["poster_url"]).path |> String.split("/") |> List.last()
    assert Assets.poster(Plug.Test.conn(:get, "/"), token).status == 200
    DB.query("UPDATE sessions SET revoked=true WHERE id=$1", [DB.uuid(ctx.session)])

    assert catch_throw(Assets.poster(Plug.Test.conn(:get, "/"), token)) ==
             {:error, "AUTH_EXPIRED"}
  end
end
