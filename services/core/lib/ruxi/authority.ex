defmodule Ruxi.Authority do
  @moduledoc "Rebuild structural recovery caches from committed SQL facts at room ownership acquisition."
  alias Ruxi.{DB, Util}

  def restore(row) do
    s = row["state_json"]
    rid = row["id"]

    version =
      DB.one("SELECT graph,content_hash FROM content_versions WHERE id=$1", [
        DB.uuid(s["content_version_id"])
      ])

    Util.require!(
      version != nil and Util.hash(version["graph"]) == version["content_hash"],
      "CONTENT_INVALID"
    )

    members =
      DB.rows(
        "SELECT id,user_id,role_code,status,control_generation,device_id FROM room_members WHERE room_id=$1",
        [rid]
      )

    by_id = Map.new(members, &{DB.str(&1["id"]), &1})
    Util.require!(length(members) == length(s["members"]), "STATE_INCONSISTENT")

    s =
      Map.update!(s, "members", fn cached ->
        Enum.map(cached, fn m ->
          fact = by_id[m["id"]]

          Util.require!(
            fact != nil and DB.str(fact["user_id"]) == m["user_id"],
            "STATE_INCONSISTENT"
          )

          Map.merge(m, %{
            "role" => fact["role_code"],
            "left" => fact["status"] == "left",
            "generation" => fact["control_generation"],
            "device" => DB.str(fact["device_id"])
          })
        end)
      end)

    items =
      DB.rows("SELECT item_id,owner_member_id,version FROM room_items WHERE room_id=$1", [rid])
      |> Map.new(
        &{&1["item_id"], %{"owner" => DB.str(&1["owner_member_id"]), "version" => &1["version"]}}
      )

    offers =
      DB.rows(
        "SELECT id,from_member_id,to_member_id,item_id,status,expires_at,item_version FROM item_offers WHERE room_id=$1 ORDER BY expires_at,id",
        [rid]
      )
      |> Enum.map(fn o ->
        %{
          "id" => DB.str(o["id"]),
          "from" => DB.str(o["from_member_id"]),
          "to" => DB.str(o["to_member_id"]),
          "item_id" => o["item_id"],
          "status" => o["status"],
          "expires" => o["expires_at"],
          "version" => o["item_version"]
        }
      end)

    s =
      Map.merge(s, %{
        "content" => version["graph"],
        "lifecycle" => row["lifecycle"],
        "deadline" => row["deadline_at"],
        "items" => items,
        "offers" => offers,
        "public_timeline" => Ruxi.PublicRecap.restore(rid),
        "story_id" =>
          DB.str(
            DB.one("SELECT story_id FROM content_versions WHERE id=$1", [
              DB.uuid(s["content_version_id"])
            ])["story_id"]
          )
      })

    if s["round"] do
      round_id = DB.uuid(s["round"]["round_id"])
      round = DB.one("SELECT * FROM vote_rounds WHERE room_id=$1 AND id=$2", [rid, round_id])
      Util.require!(round != nil, "STATE_INCONSISTENT")

      electorate =
        DB.rows(
          "SELECT member_id FROM vote_electorate WHERE room_id=$1 AND round_id=$2 ORDER BY member_id",
          [rid, round_id]
        )
        |> Enum.map(&DB.str(&1["member_id"]))

      votes =
        DB.rows("SELECT member_id,option_id FROM votes WHERE room_id=$1 AND round_id=$2", [
          rid,
          round_id
        ])
        |> Map.new(&{DB.str(&1["member_id"]), &1["option_id"]})

      definition = version["graph"]["decision"]

      cache =
        Map.merge(s["round"], %{
          "options" => round["options_json"],
          "display_options" => round["display_options_json"],
          "status" => round["status"],
          "electorate" => electorate,
          "tie_priority" => definition["tie_priority"],
          "default_option" => definition["default_option"]
        })

      cache =
        if round["status"] == "settled" do
          settlement =
            DB.one("SELECT winner,tally FROM vote_settlements WHERE room_id=$1 AND round_id=$2", [
              rid,
              round_id
            ])

          Util.require!(settlement != nil and s["phase"] == "ending", "STATE_INCONSISTENT")
          Map.merge(cache, settlement)
        else
          cache
        end

      Map.merge(s, %{"round" => cache, "votes" => votes})
    else
      s
    end
  end
end
