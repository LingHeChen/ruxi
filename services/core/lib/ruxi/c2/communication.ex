defmodule Ruxi.C2.Communication do
  @moduledoc "Private room communication, independent of game intents and AP."
  alias Ruxi.{Auth, DB, Util, Limiter}

  def context!(ctx, id, lock \\ false) do
    Auth.valid!(ctx)

    r =
      DB.one("SELECT * FROM c2_rooms WHERE id=$1" <> if(lock, do: " FOR UPDATE", else: ""), [
        DB.uuid(id)
      ])

    Util.require!(r != nil, "TARGET_UNAVAILABLE")

    m =
      DB.one("SELECT * FROM c2_room_members WHERE room_id=$1 AND user_id=$2", [
        r["id"],
        DB.uuid(ctx.user)
      ])

    Util.require!(m != nil, "TARGET_UNAVAILABLE")
    {r, m}
  end

  def control!(ctx, m, p) do
    Util.require!(
      m["device_id"] == DB.uuid(ctx.device) and m["control_epoch"] == p["control_epoch"],
      "CONTROL_LOST"
    )
  end

  def history(ctx, id) do
    {r, m} = context!(ctx, id)

    messages =
      DB.rows(
        "SELECT x.id,x.sender_id,x.scope,x.body,x.created_at,s.display_name FROM c2_chat_messages x JOIN c2_chat_recipients a ON a.message_id=x.id JOIN c2_room_members b ON b.id=x.sender_id JOIN users s ON s.id=b.user_id WHERE a.room_id=$1 AND a.member_id=$2 ORDER BY x.created_at DESC,x.id DESC LIMIT 100",
        [r["id"], m["id"]]
      )

    %{
      "messages" => Enum.reverse(Enum.map(messages, &message/1)),
      "scopes" => scopes(r, m),
      "own_member_id" => DB.str(m["id"])
    }
  end

  defp message(x), do: x |> Map.update!("id", &DB.str/1) |> Map.update!("sender_id", &DB.str/1)

  defp scopes(r, m),
    do:
      ["global"] ++
        if(actor(r, m)["location"], do: ["scene"], else: []) ++
        if(actor(r, m)["faction"], do: ["faction"], else: [])

  def actor(r, m), do: get_in(r, ["state", "actors", m["role_id"]]) || %{}
  defp recipients(r, _m, "global"), do: members(r)

  defp recipients(r, m, scope) do
    key = if scope == "scene", do: "location", else: "faction"
    own = actor(r, m)[key]
    Util.require!(own != nil, "NOT_ALLOWED")
    Enum.filter(members(r), &(actor(r, &1)[key] == own))
  end

  def members(r),
    do: DB.rows("SELECT * FROM c2_room_members WHERE room_id=$1 ORDER BY id", [r["id"]])

  def send(ctx, id, p) do
    result =
      DB.transaction(fn ->
        {r, m} = context!(ctx, id, true)
        control!(ctx, m, p)

        Util.require!(
          Map.keys(p) |> Enum.sort() == Enum.sort(~w(request_id control_epoch scope text)),
          "INPUT_INVALID"
        )

        Util.require!(
          Ecto.UUID.cast(p["request_id"]) != :error and p["scope"] in scopes(r, m) and
            is_binary(p["text"]),
          "INPUT_INVALID"
        )

        text =
          p["text"] |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "") |> String.trim()

        Util.require!(
          String.length(text) in 1..1000 and
            not Enum.any?(~w(傻逼 操你妈 去死), &String.contains?(text, &1)),
          "INPUT_INVALID"
        )

        hash = Util.hash(p)

        old =
          DB.one(
            "SELECT * FROM c2_chat_messages WHERE room_id=$1 AND sender_id=$2 AND request_id=$3",
            [r["id"], m["id"], DB.uuid(p["request_id"])]
          )

        if old do
          Util.require!(old["fingerprint"] == hash, "IDEMPOTENCY_CONFLICT")
          %{"message_id" => DB.str(old["id"])}
        else
          Util.require!(r["status"] in ~w(lobby active suspended ending), "NOT_ALLOWED")
          Limiter.check!({:c2_chat, DB.str(m["id"])}, 0.5, 10)
          mid = Util.id()
          now = DB.time()

          DB.query("INSERT INTO c2_chat_messages VALUES($1,$2,$3,$4,$5,$6,$7,$8)", [
            DB.uuid(mid),
            r["id"],
            m["id"],
            DB.uuid(p["request_id"]),
            hash,
            p["scope"],
            text,
            now
          ])

          for recipient <- recipients(r, m, p["scope"]),
              do:
                DB.query("INSERT INTO c2_chat_recipients VALUES($1,$2,$3)", [
                  r["id"],
                  DB.uuid(mid),
                  recipient["id"]
                ])

          %{"message_id" => mid}
        end
      end)

    if match?({:ok, _}, result), do: Ruxi.SceneVoice.Coordinator.notify(id)
    result
  end

  def report(ctx, id, p, kind) do
    DB.transaction(fn ->
      {r, m} = context!(ctx, id, true)

      Util.require!(
        Ecto.UUID.cast(p["request_id"]) != :error &&
          p["reason_code"] in ~w(harassment noise other) && is_binary(p["description"] || "") &&
          String.length(p["description"] || "") <= 1000,
        "INPUT_INVALID"
      )

      Limiter.check!({:communication_report, DB.str(m["id"])}, 0.1, 5)

      old =
        DB.one(
          "SELECT * FROM c2_communication_reports WHERE room_id=$1 AND reporter_id=$2 AND request_id=$3",
          [r["id"], m["id"], DB.uuid(p["request_id"])]
        )

      hash = Util.hash(p)

      if old do
        Util.require!(old["fingerprint"] == hash, "IDEMPOTENCY_CONFLICT")
        %{"report_id" => DB.str(old["id"])}
      else
        target =
          DB.one("SELECT * FROM c2_room_members WHERE room_id=$1 AND id=$2", [
            r["id"],
            DB.uuid(p["target_member_id"])
          ])

        current =
          target && actor(r, m)["location"] &&
            actor(r, m)["location"] == actor(r, target)["location"]

        seen =
          DB.one(
            "SELECT count(*) AS n FROM c2_chat_messages x JOIN c2_chat_recipients a ON x.id=a.message_id WHERE a.room_id=$1 AND a.member_id=$2 AND x.sender_id=$3 AND x.created_at>$4",
            [r["id"], m["id"], DB.uuid(p["target_member_id"]), DB.time() - 600_000]
          )["n"] > 0

        overlap =
          DB.one(
            "SELECT count(*) AS n FROM c2_voice_leases a JOIN c2_voice_leases b ON a.channel_id=b.channel_id WHERE a.room_id=$1 AND a.member_id=$2 AND b.member_id=$3 AND least(a.last_seen_at,b.last_seen_at)>$4",
            [r["id"], m["id"], DB.uuid(p["target_member_id"]), DB.time() - 600_000]
          )["n"] > 0

        Util.require!(
          target && target["id"] != m["id"] &&
            if(kind == "voice", do: current || overlap, else: seen),
          "TARGET_UNAVAILABLE"
        )

        report = Util.id()

        DB.query("INSERT INTO c2_communication_reports VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)", [
          DB.uuid(report),
          r["id"],
          m["id"],
          target["id"],
          DB.uuid(p["request_id"]),
          hash,
          kind,
          p["reason_code"],
          p["description"] || "",
          DB.time()
        ])

        %{"report_id" => report}
      end
    end)
  end

  def voice(ctx, id), do: Ruxi.SceneVoice.Coordinator.state(ctx, id)
  def voice_request(ctx, id, p), do: Ruxi.SceneVoice.Coordinator.request(ctx, id, p)
end
