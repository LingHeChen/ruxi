defmodule Ruxi.Admin do
  alias Ruxi.{DB, Auth, Util, Content}

  def dispatch("GET", ["stories"], _, ctx) do
    Auth.role!(ctx, "editor")

    %{
      "items" =>
        DB.rows(
          "SELECT id,title,summary,seat_count,current_version_id FROM stories ORDER BY title LIMIT 100"
        )
        |> Enum.map(fn row ->
          Map.merge(row, %{
            "story_id" => DB.str(row["id"]),
            "current_version_id" => DB.str(row["current_version_id"])
          })
          |> Map.delete("id")
        end),
      "next_cursor" => nil
    }
  end

  def dispatch("GET", ["stories", sid, "versions"], _, ctx) do
    Auth.role!(ctx, "editor")

    %{
      "items" =>
        DB.rows(
          "SELECT id,revision,status,availability,published_at FROM content_versions WHERE story_id=$1 ORDER BY revision DESC,id LIMIT 100",
          [DB.uuid(sid)]
        )
        |> Enum.map(fn row ->
          Map.put(row, "version_id", DB.str(row["id"])) |> Map.delete("id")
        end),
      "next_cursor" => nil
    }
  end

  def dispatch("POST", ["versions", id, "preview"], p, ctx) do
    RuxiWeb.Router.json!(p, ~w(revision command_id))
    Auth.role!(ctx, "editor")

    Auth.account(ctx, "admin.preview.create", Map.put(p, "version_id", id), fn ->
      v = version!(id, false)
      Util.require!(v["revision"] == p["revision"], "REVISION_CONFLICT")
      Util.require!(Content.validate(v["graph"])["valid"], "CONTENT_INVALID")
      Ruxi.Preview.create(v, ctx.user)
    end)
  end

  def dispatch("POST", ["previews", "step"], p, ctx) do
    RuxiWeb.Router.json!(
      p,
      ~w(preview_token actor_role type payload command_id),
      ~w(target_version)
    )

    Auth.role!(ctx, "editor")

    Auth.account(ctx, "admin.preview.step", p, fn ->
      v = version!(Ruxi.Preview.version_id(p["preview_token"]), false)
      Ruxi.Preview.step(p["preview_token"], ctx.user, v, p)
    end)
  end

  def dispatch("GET", ["versions", id], _, ctx) do
    Auth.role!(ctx, "editor")
    v = version!(id, false)

    %{
      "version_id" => id,
      "graph" => v["graph"],
      "revision" => v["revision"],
      "hash" => v["content_hash"],
      "status" => v["status"],
      "validation" => v["validation"]
    }
  end

  def dispatch("GET", ["jobs", id], _, ctx) do
    Auth.role!(ctx, "editor")
    r = DB.one("SELECT report FROM admin_jobs WHERE id=$1", [DB.uuid(id)])
    Util.require!(r != nil, "RESOURCE_NOT_FOUND")
    r["report"]
  end

  def dispatch("PUT", ["versions", id], p, ctx) do
    RuxiWeb.Router.json!(p, ~w(revision graph))
    Auth.role!(ctx, "editor")

    DB.transaction(fn ->
      v = version!(id, true)
      Util.require!(v["status"] != "published", "NOT_ALLOWED")
      Util.require!(v["revision"] == p["revision"], "REVISION_CONFLICT")
      g = p["graph"]
      Util.require!(is_map(g), "INVALID_ARGUMENT")
      Util.require!(g["story_id"] == DB.str(v["story_id"]), "INVALID_ARGUMENT")
      h = Util.hash(g)

      DB.query(
        "UPDATE content_versions SET graph=$2,revision=revision+1,content_hash=$3,approved_hash=NULL,validation=NULL,status='draft' WHERE id=$1",
        [DB.uuid(id), g, h]
      )

      %{"revision" => v["revision"] + 1, "hash" => h}
    end)
  end

  def dispatch("POST", ["stories"], p, ctx) do
    RuxiWeb.Router.json!(p, ~w(title summary seat_count command_id))
    Auth.role!(ctx, "editor")

    Auth.account(ctx, "admin.story.create", p, fn ->
      Util.require!(
        p["seat_count"] in 2..4 and is_binary(p["title"]) and is_binary(p["summary"]),
        "INVALID_ARGUMENT"
      )

      id = Util.id()

      DB.query("INSERT INTO stories(id,title,summary,seat_count) VALUES($1,$2,$3,$4)", [
        DB.uuid(id),
        p["title"],
        p["summary"],
        p["seat_count"]
      ])

      audit(ctx, "story.create", id)
      %{"story_id" => id}
    end)
  end

  def dispatch("POST", ["stories", sid, "versions"], p, ctx) do
    RuxiWeb.Router.json!(p, ~w(command_id), ~w(base_version_id))
    Auth.role!(ctx, "editor")

    Auth.account(ctx, "admin.version.create", Map.put(p, "story_id", sid), fn ->
      g =
        if p["base_version_id"],
          do: version!(p["base_version_id"], false)["graph"],
          else: Content.demo_graph()

      g = Map.put(g, "story_id", sid)

      id = Util.id()

      DB.query(
        "INSERT INTO content_versions(id,story_id,graph,content_hash,status) VALUES($1,$2,$3,$4,'draft')",
        [DB.uuid(id), DB.uuid(sid), g, Util.hash(g)]
      )

      audit(ctx, "version.create", id)
      %{"version_id" => id, "revision" => 1}
    end)
  end

  def dispatch("POST", ["versions", id, op], p, ctx)
      when op in ~w(validate approve publish availability) do
    fields =
      case op do
        "validate" -> ~w(command_id revision)
        "approve" -> ~w(command_id revision content_hash)
        "publish" -> ~w(command_id revision approved_hash)
        "availability" -> ~w(command_id availability reason)
      end

    RuxiWeb.Router.json!(p, fields)

    Auth.role!(
      ctx,
      %{
        "validate" => "editor",
        "approve" => "reviewer",
        "publish" => "publisher",
        "availability" => "publisher"
      }[op]
    )

    Auth.account(ctx, "admin.version." <> op, Map.put(p, "version_id", id), fn ->
      v = version!(id, true)

      if op != "availability",
        do: Util.require!(v["revision"] == p["revision"], "REVISION_CONFLICT")

      result =
        case op do
          "validate" ->
            report = Content.validate(v["graph"])
            j = Util.id()

            DB.query("UPDATE content_versions SET validation=$2 WHERE id=$1", [
              DB.uuid(id),
              report
            ])

            DB.query("INSERT INTO admin_jobs(id,version_id,report) VALUES($1,$2,$3)", [
              DB.uuid(j),
              DB.uuid(id),
              report
            ])

            %{"job_id" => j}

          "approve" ->
            Util.require!(
              (v["validation"] && v["validation"]["valid"]) and
                p["content_hash"] == v["content_hash"],
              "NOT_ALLOWED"
            )

            DB.query(
              "UPDATE content_versions SET approved_hash=$2,status='approved' WHERE id=$1",
              [DB.uuid(id), v["content_hash"]]
            )

            %{"approved_hash" => v["content_hash"]}

          "publish" ->
            Util.require!(
              (v["validation"] && v["validation"]["assets_ready"] == true) and
                v["approved_hash"] == p["approved_hash"] and
                p["approved_hash"] == v["content_hash"],
              "NOT_ALLOWED"
            )

            now = DB.time()

            Util.require!(
              Content.validate(v["graph"])["valid"] and Ruxi.Media.ready?(v["graph"]),
              "CONTENT_INVALID"
            )

            DB.query(
              "UPDATE content_versions SET status='published',published_at=$2 WHERE id=$1",
              [DB.uuid(id), now]
            )

            DB.query("UPDATE stories SET current_version_id=$2 WHERE id=$1", [
              v["story_id"],
              DB.uuid(id)
            ])

            DB.query("UPDATE stories SET title=$2,seat_count=$3 WHERE id=$1", [
              v["story_id"],
              v["graph"]["title"],
              v["graph"]["seat_count"]
            ])

            %{"published_at" => Util.iso(now), "content_version_id" => id}

          "availability" ->
            Util.require!(p["availability"] in ~w(available unlisted blocked), "INVALID_ARGUMENT")

            DB.query("UPDATE content_versions SET availability=$2 WHERE id=$1", [
              DB.uuid(id),
              p["availability"]
            ])

            %{"availability" => p["availability"]}
        end

      audit(ctx, op, id)
      result
    end)
  end

  def dispatch(_, _, _, _), do: Util.fail("RESOURCE_NOT_FOUND")

  defp version!(id, lock) do
    v =
      DB.one(
        "SELECT * FROM content_versions WHERE id=$1" <> if(lock, do: " FOR UPDATE", else: ""),
        [DB.uuid(id)]
      )

    Util.require!(v != nil, "RESOURCE_NOT_FOUND")
    v
  end

  defp audit(ctx, op, id),
    do:
      DB.query(
        "INSERT INTO audit_log(id,user_id,operation,target_id,occurred_at) VALUES($1,$2,$3,$4,$5)",
        [DB.uuid(Util.id()), DB.uuid(ctx.user), op, DB.uuid(id), DB.time()]
      )
end
