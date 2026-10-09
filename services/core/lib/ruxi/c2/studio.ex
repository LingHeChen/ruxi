defmodule Ruxi.C2.Studio do
  alias Ruxi.{DB, Auth, Util}
  alias Ruxi.C2.{Content, Engine}

  def project!(ctx, id, role \\ "editor", lock \\ false) do
    Auth.valid!(ctx)
    Auth.role!(ctx, role)

    p =
      DB.one("SELECT * FROM c2_projects WHERE id=$1" <> if(lock, do: " FOR UPDATE", else: ""), [
        DB.uuid(id)
      ])

    Util.require!(p != nil, "RESOURCE_NOT_FOUND")

    allowed =
      DB.one("SELECT roles FROM c2_project_members WHERE project_id=$1 AND user_id=$2", [
        DB.uuid(id),
        DB.uuid(ctx.user)
      ])

    Util.require!(
      DB.str(p["owner_id"]) == ctx.user or (allowed != nil and role in allowed["roles"]),
      "RESOURCE_NOT_FOUND"
    )

    p
  end

  def list(ctx) do
    Auth.role!(ctx, "editor")

    %{
      "items" =>
        DB.rows(
          "SELECT p.id,p.title,p.summary,p.category,p.difficulty,p.revision,p.layout_revision,p.current_release_id,p.archived_at,p.updated_at,jsonb_array_length(p.content->'roles') AS seat_count,jsonb_array_length(p.content->'locations') AS location_count FROM c2_projects p WHERE p.owner_id=$1 OR EXISTS(SELECT 1 FROM c2_project_members m WHERE m.project_id=p.id AND m.user_id=$1) ORDER BY p.updated_at DESC LIMIT 100",
          [DB.uuid(ctx.user)]
        )
        |> Enum.map(&serialize/1),
      "next_cursor" => nil
    }
  end

  def get(ctx, id), do: project!(ctx, id) |> serialize()

  defp serialize(p),
    do:
      p
      |> Map.update!("id", &DB.str/1)
      |> Map.update("owner_id", nil, &DB.str/1)
      |> Map.update("current_release_id", nil, &DB.str/1)

  def create(ctx, p) do
    Auth.role!(ctx, "editor")

    Util.require!(
      is_binary(p["title"]) and String.length(p["title"]) in 1..120 and p["seat_count"] in 1..6,
      "INVALID_ARGUMENT"
    )

    id = Util.id()
    now = DB.time()
    s = blank(p["title"], p["seat_count"], p["rules"])

    DB.query(
      "INSERT INTO c2_projects(id,owner_id,title,summary,category,content,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$7)",
      [
        DB.uuid(id),
        DB.uuid(ctx.user),
        p["title"],
        p["summary"] || "",
        p["category"] || "mystery",
        s,
        now
      ]
    )

    audit(ctx, id, "project.create")
    get(ctx, id)
  end

  def blank(title, seats, rules \\ nil) do
    roles =
      Enum.map(
        1..seats,
        &%{
          "id" => "role_#{&1}",
          "label" => "角色 #{&1}",
          "location" => "start",
          "knowledge" => [],
          "goals" => []
        }
      )

    %{
      "schema_version" => 3,
      "id" => "world_" <> String.replace(Util.id(), "-", ""),
      "title" => title,
      "rules" =>
        rules ||
          %{
            "ap_per_round" => 3,
            "step_timeout_s" => 45,
            "proposal_ttl_s" => 60,
            "round_limit" => 4
          },
      "roles" => roles,
      "locations" => [
        %{"id" => "start", "label" => "起点", "description" => "请编辑场景描述", "discovered" => true}
      ],
      "links" => [],
      "objects" => [],
      "clues" => [],
      "actions" => [],
      "templates" => [],
      "events" => [],
      "initial" => %{"world" => %{}, "inventory" => Map.new(roles, &{&1["id"], []})},
      "media" => []
    }
    |> then(fn story ->
      if seats >= 1,
        do:
          Map.merge(story, %{
            "schema_version" => 4,
            "c3" => %{
              "profile_version" => 1,
              "suggested_content_version" => 4,
              "map_mode" => "mixed",
              "passages" => [],
              "interactions" => []
            },
            "secrets" => %{},
            "c3_settings" => %{"barriers" => %{}, "arrival_rules" => %{}}
          }),
        else: story
    end)
  end

  def draft(ctx, id),
    do:
      project!(ctx, id)
      |> then(
        &%{
          "project_id" => id,
          "revision" => &1["revision"],
          "content" => &1["content"],
          "validation" => &1["validation"],
          "reviewed_hash" => &1["reviewed_hash"],
          "hash" => Util.hash(&1["content"])
        }
      )

  def save(ctx, id, content, revision) do
    p = project!(ctx, id, "editor", true)
    revision!(p["revision"], revision)

    Util.require!(
      p["archived_at"] == nil and is_map(content) and content["schema_version"] in [3, 4] and
        byte_size(Jason.encode!(content)) <= 1_000_000,
      "INVALID_ARGUMENT"
    )

    DB.query(
      "UPDATE c2_projects SET content=$2,title=$3,revision=revision+1,validation=NULL,reviewed_hash=NULL,updated_at=$4 WHERE id=$1",
      [DB.uuid(id), content, content["title"] || p["title"], DB.time()]
    )

    audit(ctx, id, "draft.save")
    draft(ctx, id)
  end

  def revision!(actual, given),
    do: Util.require!(is_integer(given) and given == actual, "REVISION_CONFLICT")

  def layout(ctx, id),
    do:
      project!(ctx, id)
      |> then(&%{"layout_revision" => &1["layout_revision"], "layout" => &1["layout"]})

  def save_layout(ctx, id, layout, revision) do
    p = project!(ctx, id, "editor", true)
    revision!(p["layout_revision"], revision)

    Util.require!(
      is_map(layout) and byte_size(Jason.encode!(layout)) <= 200_000,
      "INVALID_ARGUMENT"
    )

    DB.query("UPDATE c2_projects SET layout=$2,layout_revision=layout_revision+1 WHERE id=$1", [
      DB.uuid(id),
      layout
    ])

    %{"layout_revision" => revision + 1, "layout" => layout}
  end

  def validate(ctx, id) do
    p = project!(ctx, id, "editor", true)
    r = Content.validate(p["content"])
    DB.query("UPDATE c2_projects SET validation=$2 WHERE id=$1", [DB.uuid(id), r])
    r
  end

  def review(ctx, id, body) do
    p = project!(ctx, id, "reviewer", true)
    r = Content.validate(p["content"])

    Util.require!(
      body["decision"] in ~w(approve reject) and is_binary(body["reason"]) and
        String.length(body["reason"]) in 1..1000,
      "INVALID_ARGUMENT"
    )

    Util.require!(body["content_hash"] == Util.hash(p["content"]), "REVISION_CONFLICT")
    if body["decision"] == "approve", do: Util.require!(r["valid"], "CONTENT_INVALID")
    rid = Util.id()

    DB.query(
      "INSERT INTO c2_reviews(id,project_id,content_hash,decision,reason,actor_id,created_at) VALUES($1,$2,$3,$4,$5,$6,$7)",
      [
        DB.uuid(rid),
        DB.uuid(id),
        body["content_hash"],
        body["decision"],
        body["reason"],
        DB.uuid(ctx.user),
        DB.time()
      ]
    )

    DB.query("UPDATE c2_projects SET validation=$2,reviewed_hash=$3 WHERE id=$1", [
      DB.uuid(id),
      r,
      if(body["decision"] == "approve", do: body["content_hash"], else: nil)
    ])

    audit(ctx, id, "review." <> body["decision"])
    %{"review_id" => rid, "content_hash" => body["content_hash"], "decision" => body["decision"]}
  end

  def publish(ctx, id, body) do
    p = project!(ctx, id, "publisher", true)
    hash = Util.hash(p["content"])

    Util.require!(
      p["archived_at"] == nil and hash == p["reviewed_hash"] and body["content_hash"] == hash,
      "NOT_ALLOWED"
    )

    Content.compile!(p["content"])

    Util.require!(
      Enum.all?(p["content"]["media"], &Ruxi.C3.Art.publishable?/1),
      "MEDIA_UNAVAILABLE"
    )

    # Images must match the shipped bundle's SHA-256 manifest. Arbitrary URLs are never accepted.
    existing =
      DB.one("SELECT id FROM c2_releases WHERE project_id=$1 AND content_hash=$2", [
        DB.uuid(id),
        hash
      ])

    release_id = if existing, do: DB.str(existing["id"]), else: Util.id()

    DB.query(
      "INSERT INTO c2_releases(id,project_id,content_hash,content,status,created_by,published_at) VALUES($1,$2,$3,$4,'published',$5,$6) ON CONFLICT(project_id,content_hash) DO NOTHING",
      [DB.uuid(release_id), DB.uuid(id), hash, p["content"], DB.uuid(ctx.user), DB.time()]
    )

    DB.query("UPDATE c2_projects SET current_release_id=$2 WHERE id=$1", [
      DB.uuid(id),
      DB.uuid(release_id)
    ])

    audit(ctx, id, "release.publish")
    %{"release_id" => release_id, "content_hash" => hash}
  end

  def releases(ctx, id) do
    project!(ctx, id)

    %{
      "items" =>
        DB.rows(
          "SELECT id,content_hash,status,published_at FROM c2_releases WHERE project_id=$1 ORDER BY published_at DESC",
          [DB.uuid(id)]
        )
        |> Enum.map(&Map.update!(&1, "id", fn x -> DB.str(x) end)),
      "next_cursor" => nil
    }
  end

  def withdraw(ctx, release_id, body, blocked) do
    release = DB.one("SELECT * FROM c2_releases WHERE id=$1", [DB.uuid(release_id)])
    Util.require!(release != nil, "RESOURCE_NOT_FOUND")
    project = project!(ctx, DB.str(release["project_id"]), "publisher", true)

    Util.require!(
      is_binary(body["reason"]) and String.length(body["reason"]) in 1..1000,
      "INVALID_ARGUMENT"
    )

    status = if blocked, do: "blocked", else: "withdrawn"
    DB.query("UPDATE c2_releases SET status=$2 WHERE id=$1", [DB.uuid(release_id), status])

    if project["current_release_id"] == release["id"],
      do: DB.query("UPDATE c2_projects SET current_release_id=NULL WHERE id=$1", [project["id"]])

    if blocked, do: Ruxi.C2.Store.block_release(release_id)
    audit(ctx, DB.str(project["id"]), "release." <> status)
    %{"status" => status}
  end

  def archive(ctx, id) do
    project!(ctx, id, "editor", true)

    DB.query("UPDATE c2_projects SET archived_at=$2,current_release_id=NULL WHERE id=$1", [
      DB.uuid(id),
      DB.time()
    ])

    audit(ctx, id, "project.archive")
    %{"archived" => true}
  end

  def metadata(ctx, id, body, revision) do
    p = project!(ctx, id, "editor", true)
    revision!(p["revision"], revision)
    category = body["category"] || p["category"]
    difficulty = body["difficulty"] || p["difficulty"]
    summary = body["summary"] || p["summary"]

    Util.require!(
      category in ~w(mystery emotion scifi adventure) and
        difficulty in ~w(beginner intermediate advanced) and is_binary(summary) and
        String.length(summary) <= 2000,
      "INVALID_ARGUMENT"
    )

    DB.query(
      "UPDATE c2_projects SET category=$2,difficulty=$3,summary=$4,revision=revision+1,updated_at=$5 WHERE id=$1",
      [DB.uuid(id), category, difficulty, summary, DB.time()]
    )

    get(ctx, id)
  end

  def export(ctx, id) do
    p = project!(ctx, id)

    %{
      "story" => p["content"],
      "editor_layout" => p["layout"],
      "schema_version" => p["content"]["schema_version"],
      "audience" => "author_only",
      "contains_server_secrets" => map_size(p["content"]["secrets"] || %{}) > 0,
      "revision" => p["revision"],
      "sources" =>
        DB.rows("SELECT id,title,source_hash,rights_note FROM c2_sources WHERE project_id=$1", [
          DB.uuid(id)
        ])
        |> Enum.map(&Map.update!(&1, "id", fn x -> DB.str(x) end))
    }
  end

  def import(ctx, body) do
    graph = body["story"]

    Util.require!(
      is_map(graph) and graph["schema_version"] in [3, 4] and is_list(graph["roles"]) and
        length(graph["roles"]) in 1..6,
      "INVALID_ARGUMENT"
    )

    p = create(ctx, %{"title" => graph["title"], "seat_count" => length(graph["roles"])})
    id = p["id"]
    saved = save(ctx, id, graph, 1)
    if is_map(body["editor_layout"]), do: save_layout(ctx, id, body["editor_layout"], 1)
    saved
  end

  def preview(ctx, id, body) do
    p = project!(ctx, id)
    s = Content.compile!(p["content"])
    now = DB.time()
    pid = Util.id()

    seed =
      if is_integer(body["seed"]),
        do: :crypto.hash(:sha256, to_string(body["seed"])),
        else: :crypto.strong_rand_bytes(32)

    state = Engine.initial(s, now, random_key: seed)

    DB.query(
      "INSERT INTO c2_previews(id,project_id,user_id,revision,state,clock,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)",
      [DB.uuid(pid), DB.uuid(id), DB.uuid(ctx.user), p["revision"], state, now, now + 3_600_000]
    )

    preview_response(pid, state, now)
  end

  def projection_preview(ctx, id, body) do
    p = project!(ctx, id)
    revision!(p["revision"], body["draft_revision"])
    Content.compile!(p["content"])
    role = body["role_id"]
    Util.require!(Map.has_key?(Content.index(p["content"], "roles"), role), "INVALID_ARGUMENT")
    s = Engine.initial(p["content"], 0)
    fixture = body["fixture_id"] || "initial"
    Util.require!(fixture in ~w(initial blocked repaired), "INVALID_ARGUMENT")

    s =
      if fixture != "initial" and s["engine_version"] == 3 do
        Map.update!(s, "barriers", fn xs ->
          Map.new(xs, fn {k, _} -> {k, if(fixture == "blocked", do: "blocked", else: "open")} end)
        end)
        |> Ruxi.C3.World.observe(1)
      else
        s
      end

    %{
      "draft_revision" => p["revision"],
      "role_id" => role,
      "fixture_id" => fixture,
      "view" => Engine.project(s, role, 1)
    }
  end

  def preview_step(ctx, id, body) do
    v = DB.one("SELECT * FROM c2_previews WHERE id=$1 FOR UPDATE", [DB.uuid(id)])

    Util.require!(
      v != nil and DB.str(v["user_id"]) == ctx.user and v["expires_at"] > DB.time(),
      "RESOURCE_NOT_FOUND"
    )

    p = project!(ctx, DB.str(v["project_id"]))
    revision!(p["revision"], v["revision"])
    s = v["state"]
    clock = v["clock"]

    {s, clock} =
      if body["type"] == "advance_time" do
        delta = body["body"]["delta_ms"]
        Util.require!(is_integer(delta) and delta in 1..300_000, "INVALID_ARGUMENT")

        case Engine.tick(s, clock + delta) do
          {:ok, next} -> {next, clock + delta}
          {:error, _, next} -> {next, clock + delta}
        end
      else
        case Engine.command(
               s,
               body["actor_role"],
               body["type"],
               body["body"],
               body["command_id"],
               clock
             ) do
          {:ok, next, _} -> {next, clock}
          {:error, code, _} -> Util.fail(code)
        end
      end

    Util.require!(length(s["settlements"]) <= 500, "PREVIEW_LIMIT")
    DB.query("UPDATE c2_previews SET state=$2,clock=$3 WHERE id=$1", [DB.uuid(id), s, clock])
    preview_response(id, s, clock)
  end

  defp preview_response(id, state, clock),
    do: %{
      "preview_id" => id,
      "clock" => clock,
      "views" => Map.new(Map.keys(state["actors"]), &{&1, Engine.project(state, &1, clock)}),
      "settlements" => state["settlements"]
    }

  def audit(ctx, id, action),
    do:
      DB.query(
        "INSERT INTO c2_audit(actor_id,scope,entity_id,action,created_at) VALUES($1,'project',$2,$3,$4)",
        [DB.uuid(ctx.user), DB.uuid(id), action, DB.time()]
      )
end
