defmodule Ruxi.Catalog do
  alias Ruxi.{Auth, DB, Util}
  @categories ~w(mystery emotion scifi adventure)
  def list(q) do
    query = q["q"] || ""
    category = q["category"] || ""
    seats = q["seats"] || ""
    sort = q["sort"] || "latest"
    offset = q["offset"] || "0"

    Util.require!(
      is_binary(query) and String.length(query) <= 80 and category in ["" | @categories] and
        seats in (~w(2 3 4) ++ [""]) and sort in ~w(latest title) and
        Regex.match?(~r/^\d{1,5}$/, offset),
      "INVALID_ARGUMENT"
    )

    offset = String.to_integer(offset)
    params = [query, category, seats]

    where =
      " FROM stories s JOIN content_versions v ON v.id=s.current_version_id WHERE v.availability='available' AND v.status='published' AND ($1='' OR strpos(lower(s.title || ' ' || s.summary),lower($1))>0) AND ($2='' OR s.category=$2) AND ($3='' OR s.seat_count::text=$3)"

    total = DB.one("SELECT count(*) AS n" <> where, params)["n"]
    order = if sort == "title", do: "s.title,s.id", else: "v.published_at DESC NULLS LAST,s.id"

    items =
      DB.rows(
        "SELECT s.*" <> where <> " ORDER BY #{order} LIMIT 24 OFFSET $4",
        params ++ [offset]
      )
      |> Enum.map(&story/1)

    %{
      "items" => items,
      "total" => total,
      "next_cursor" =>
        if(offset + length(items) < total, do: to_string(offset + length(items)), else: nil)
    }
  end

  def detail(id) do
    row =
      DB.one(
        "SELECT s.* FROM stories s JOIN content_versions v ON v.id=s.current_version_id WHERE s.id=$1 AND v.status='published' AND v.availability='available'",
        [DB.uuid(id)]
      )

    Util.require!(row != nil, "RESOURCE_NOT_FOUND")
    story(row)
  end

  def story(row),
    do: %{
      "story_id" => DB.str(row["id"]),
      "title" => row["title"],
      "summary" => row["summary"],
      "seat_count" => row["seat_count"],
      "category" => row["category"],
      "difficulty" => row["difficulty"],
      "availability" => "available",
      "cover_url" => nil,
      "duration_range_ms" => [600_000, 900_000],
      "current_version_id" => DB.str(row["current_version_id"])
    }

  def favorites(ctx) do
    Auth.valid!(ctx)

    items =
      DB.rows(
        "SELECT s.* FROM story_favorites f JOIN stories s ON s.id=f.story_id JOIN content_versions v ON v.id=s.current_version_id WHERE f.user_id=$1 AND v.availability='available' AND v.status='published' ORDER BY f.created_at DESC LIMIT 200",
        [DB.uuid(ctx.user)]
      )
      |> Enum.map(&story/1)

    %{"items" => items}
  end

  def favorite(ctx, id, p) do
    RuxiWeb.Router.json!(p, ~w(saved command_id))
    Util.require!(is_boolean(p["saved"]), "INVALID_ARGUMENT")

    Auth.account(ctx, "favorite:" <> id, p, fn ->
      detail(id)

      if p["saved"],
        do:
          DB.query(
            "INSERT INTO story_favorites(user_id,story_id,created_at) VALUES($1,$2,$3) ON CONFLICT DO NOTHING",
            [DB.uuid(ctx.user), DB.uuid(id), DB.time()]
          ),
        else:
          DB.query("DELETE FROM story_favorites WHERE user_id=$1 AND story_id=$2", [
            DB.uuid(ctx.user),
            DB.uuid(id)
          ])

      %{"saved" => p["saved"]}
    end)
  end

  def metadata(ctx, id, p) do
    RuxiWeb.Router.json!(p, ~w(category difficulty summary command_id))
    Auth.role!(ctx, "editor")

    Util.require!(
      p["category"] in @categories and p["difficulty"] in ~w(beginner intermediate advanced) and
        is_binary(p["summary"]) and String.length(p["summary"]) <= 1000,
      "INVALID_ARGUMENT"
    )

    Auth.account(ctx, "catalog:" <> id, p, fn ->
      Util.require!(
        DB.one("SELECT id FROM stories WHERE id=$1 FOR UPDATE", [DB.uuid(id)]) != nil,
        "RESOURCE_NOT_FOUND"
      )

      DB.query("UPDATE stories SET category=$2,difficulty=$3,summary=$4 WHERE id=$1", [
        DB.uuid(id),
        p["category"],
        p["difficulty"],
        String.trim(p["summary"])
      ])

      DB.query(
        "INSERT INTO audit_log(id,user_id,operation,target_id,occurred_at) VALUES($1,$2,'catalog.metadata',$3,$4)",
        [DB.uuid(Util.id()), DB.uuid(ctx.user), DB.uuid(id), DB.time()]
      )

      %{"updated" => true}
    end)
  end

  def rooms(ctx) do
    Auth.valid!(ctx)

    items =
      DB.rows(
        "SELECT r.id,r.lifecycle,r.updated_at,s.title,s.id AS story_id,m.role_code FROM rooms r JOIN room_members m ON m.room_id=r.id JOIN content_versions v ON v.id=r.content_version_id JOIN stories s ON s.id=v.story_id WHERE m.user_id=$1 ORDER BY r.updated_at DESC LIMIT 100",
        [DB.uuid(ctx.user)]
      )
      |> Enum.map(fn r ->
        %{
          "room_id" => DB.str(r["id"]),
          "story_id" => DB.str(r["story_id"]),
          "title" => r["title"],
          "role_code" => r["role_code"],
          "lifecycle" => r["lifecycle"],
          "can_resume" => r["lifecycle"] in ~w(lobby running paused suspended),
          "updated_at" => Util.iso(r["updated_at"])
        }
      end)

    %{"items" => items, "next_cursor" => nil}
  end
end
