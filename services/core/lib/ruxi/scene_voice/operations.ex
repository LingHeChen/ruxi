defmodule Ruxi.SceneVoice.Operations do
  alias Ruxi.{DB, Auth, Util}
  alias Ruxi.C2.Communication, as: C
  alias Ruxi.SceneVoice.Coordinator, as: V
  # Explicit capability mapping for the existing operator roles.
  def authorize!(ctx, "voice:read") do
    Auth.valid!(ctx)
    Util.require!(Enum.any?(Auth.roles(ctx.user), &(&1 in ~w(reviewer publisher))), "FORBIDDEN")
  end

  def authorize!(ctx, "voice:manage"),
    do:
      (
        Auth.valid!(ctx)
        Auth.role!(ctx, "publisher")
      )

  defp room!(id) do
    r = DB.one("SELECT * FROM c2_rooms WHERE id=$1", [DB.uuid(id)])
    Util.require!(r != nil, "TARGET_UNAVAILABLE")
    r
  end

  def list(ctx) do
    authorize!(ctx, "voice:read")

    %{
      "items" =>
        DB.rows("SELECT id,status,created_at FROM c2_rooms ORDER BY created_at DESC LIMIT 100")
        |> Enum.map(&Map.update!(&1, "id", fn id -> DB.str(id) end))
    }
  end

  def get(ctx, id) do
    authorize!(ctx, "voice:read")
    r = room!(id)

    usage =
      DB.one(
        "SELECT coalesce(sum(greatest(0,coalesce(left_at,$2)-joined_at)),0)::bigint AS ms FROM c2_voice_usage WHERE room_id=$1",
        [r["id"], DB.time()]
      )["ms"] / 60_000

    %{
      "room_id" => id,
      "enabled" => not r["voice_disabled"],
      "members" =>
        DB.rows(
          "SELECT m.id AS member_id,u.display_name FROM c2_room_members m JOIN users u ON u.id=m.user_id WHERE m.room_id=$1",
          [r["id"]]
        )
        |> Enum.map(&Map.update!(&1, "member_id", fn x -> DB.str(x) end)),
      "channels" =>
        DB.rows(
          "SELECT id AS channel_ref,generation,status FROM c2_voice_channels WHERE room_id=$1 AND status != 'closed'",
          [r["id"]]
        )
        |> Enum.map(&Map.update!(&1, "channel_ref", fn x -> DB.str(x) end)),
      "pending_transition_ids" =>
        DB.rows(
          "SELECT id FROM c2_voice_transitions WHERE room_id=$1 AND phase IN ('retiring','blocked','fenced')",
          [r["id"]]
        )
        |> Enum.map(&DB.str(&1["id"])),
      "estimated_person_minutes" => usage,
      "estimated_cost_yuan" => usage * Ruxi.SceneVoice.Budget.price(),
      "restricted_member_ids" =>
        DB.rows("SELECT member_id FROM c2_voice_participation WHERE room_id=$1 AND restricted", [
          r["id"]
        ])
        |> Enum.map(&DB.str(&1["member_id"]))
    }
  end

  def request(ctx, id, p) do
    authorize!(ctx, "voice:manage")

    DB.transaction(fn ->
      r = DB.one("SELECT * FROM c2_rooms WHERE id=$1 FOR UPDATE", [DB.uuid(id)])
      Util.require!(r != nil, "TARGET_UNAVAILABLE")

      Util.require!(
        Enum.sort(Map.keys(p)) == Enum.sort(~w(request_id action reason body)) &&
          Ecto.UUID.cast(p["request_id"]) != :error && is_binary(p["reason"]) &&
          String.length(String.trim(p["reason"])) in 1..500,
        "INPUT_INVALID"
      )

      hash = Util.hash(p)

      old =
        DB.one("SELECT * FROM c2_voice_operations WHERE admin_id=$1 AND request_id=$2", [
          DB.uuid(ctx.user),
          DB.uuid(p["request_id"])
        ])

      if old do
        Util.require!(old["fingerprint"] == hash, "IDEMPOTENCY_CONFLICT")
        %{"operation_id" => DB.str(old["id"])}
      else
        case p["action"] do
          action when action in ~w(restrict_member release_member) ->
            Util.require!(
              is_map(p["body"]) && Map.keys(p["body"]) == ["member_id"],
              "INPUT_INVALID"
            )

            m =
              DB.one("SELECT * FROM c2_room_members WHERE room_id=$1 AND id=$2", [
                r["id"],
                DB.uuid(p["body"]["member_id"])
              ])

            Util.require!(m != nil, "TARGET_UNAVAILABLE")
            if action == "restrict_member", do: V.retire_for(r, m)

            DB.query(
              "INSERT INTO c2_voice_participation(room_id,member_id,device_id,control_epoch,restricted) VALUES($1,$2,$3,$4,$5) ON CONFLICT(room_id,member_id) DO UPDATE SET restricted=$5",
              [r["id"], m["id"], m["device_id"], m["control_epoch"], action == "restrict_member"]
            )

          "disable_room" ->
            Util.require!(p["body"] == %{}, "INPUT_INVALID")
            for m <- C.members(r), do: V.retire_for(r, m)

            DB.query(
              "UPDATE c2_rooms SET voice_disabled=true,voice_revision=voice_revision+1 WHERE id=$1",
              [r["id"]]
            )

          "retry_retirement" ->
            Util.require!(
              is_map(p["body"]) && Map.keys(p["body"]) == ["transition_id"],
              "INPUT_INVALID"
            )

            t = V.pending(r)

            Util.require!(
              t && DB.str(t["id"]) == p["body"]["transition_id"],
              "TARGET_UNAVAILABLE"
            )

            DB.query(
              "UPDATE c2_voice_transitions SET phase='retiring',updated_at=$2 WHERE id=$1",
              [t["id"], DB.time()]
            )

          _ ->
            Util.fail("INPUT_INVALID")
        end

        op = Util.id()

        DB.query("INSERT INTO c2_voice_operations VALUES($1,$2,$3,$4,$5,$6,$7,$8)", [
          DB.uuid(op),
          r["id"],
          DB.uuid(ctx.user),
          DB.uuid(p["request_id"]),
          hash,
          p["action"],
          p["reason"],
          DB.time()
        ])

        DB.query("INSERT INTO audit_log VALUES($1,$2,$3,$4,$5)", [
          DB.uuid(Util.id()),
          DB.uuid(ctx.user),
          "voice:" <> p["action"],
          r["id"],
          DB.time()
        ])

        %{"operation_id" => op}
      end
    end)
  end

  def operation(ctx, id, op) do
    authorize!(ctx, "voice:read")
    r = room!(id)

    o =
      DB.one("SELECT * FROM c2_voice_operations WHERE id=$1 AND room_id=$2", [
        DB.uuid(op),
        r["id"]
      ])

    Util.require!(o != nil, "TARGET_UNAVAILABLE")
    t = V.pending(r)

    member_pending =
      DB.one("SELECT id FROM c2_voice_revocations WHERE room_id=$1 AND phase='pending' LIMIT 1", [
        r["id"]
      ]) != nil

    %{
      "operation_id" => op,
      "status" =>
        if(t,
          do: if(t["phase"] == "blocked", do: "failed", else: "running"),
          else: if(member_pending, do: "running", else: "succeeded")
        ),
      "error_code" => if(t && t["phase"] == "blocked", do: "RETIREMENT_PENDING", else: nil)
    }
  end

  def reports(ctx) do
    authorize!(ctx, "voice:read")

    %{
      "items" =>
        DB.rows(
          "SELECT id,room_id,kind,reason,description,created_at FROM c2_communication_reports ORDER BY created_at DESC LIMIT 100"
        )
        |> Enum.map(fn x ->
          x |> Map.update!("id", &DB.str/1) |> Map.update!("room_id", &DB.str/1)
        end)
    }
  end
end
