defmodule Ruxi.Jobs do
  alias Ruxi.{DB, Util, Auth, Store, Rules}

  def dispatch(["claim"], p, principal) do
    RuxiWeb.Router.json!(p, ~w(worker_id supported_kinds claim_id))

    DB.transaction(fn ->
      Util.require!(
        p["worker_id"] == principal["worker_id"] and
          Ruxi.Contract.uuid?(p["claim_id"]) and
          is_list(p["supported_kinds"]) and p["supported_kinds"] != [] and
          length(p["supported_kinds"]) <= 3 and
          Enum.all?(
            p["supported_kinds"],
            &(&1 in principal["allowed_kinds"] and &1 in ~w(player_hint media_transcode editor_ai))
          ),
        "INVALID_ARGUMENT"
      )

      DB.query("SELECT pg_advisory_xact_lock(hashtext($1))", [p["worker_id"] <> p["claim_id"]])

      cached =
        DB.one("SELECT * FROM work_claims WHERE worker_id=$1 AND claim_id=$2", [
          p["worker_id"],
          DB.uuid(p["claim_id"])
        ])

      now = DB.time()

      if cached && cached["expires_at"] > now do
        reply = Auth.unseal(cached["reply_ciphertext"])
        Util.require!(reply["kind"] in p["supported_kinds"], "RESULT_CONFLICT")
        reply
      else
        job =
          DB.one(
            "SELECT * FROM work_items WHERE kind=ANY($2::text[]) AND (room_id IS NOT NULL OR attempt < 3) AND (status='queued' OR (status='leased' AND lease_until<=$1)) ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED",
            [now, p["supported_kinds"]]
          )

        if job do
          token = Util.token()
          attempt = job["attempt"] + 1

          DB.query(
            "UPDATE work_items SET status='leased',attempt=$2,lease_hash=$3,lease_until=$4,leased_by=$5 WHERE id=$1",
            [job["id"], attempt, Util.hash(token), now + 60_000, principal["worker_id"]]
          )

          reply = %{
            "job_id" => DB.str(job["id"]),
            "kind" => job["kind"],
            "attempt" => attempt,
            "lease_token" => token,
            "lease_until" => Util.iso(now + 60_000),
            "input" => job["input_json"],
            "basis" => job["basis"]
          }

          DB.query(
            "INSERT INTO work_claims(worker_id,claim_id,reply_ciphertext,expires_at) VALUES($1,$2,$3,$4) ON CONFLICT(worker_id,claim_id) DO UPDATE SET reply_ciphertext=$3,expires_at=$4",
            [p["worker_id"], DB.uuid(p["claim_id"]), DB.bytes(Auth.seal(reply)), now + 60_000]
          )

          reply
        else
          %{"job_id" => nil}
        end
      end
    end)
  end

  def dispatch([id, op], p, principal) when op in ~w(heartbeat complete fail) do
    meta = DB.one("SELECT room_id FROM work_items WHERE id=$1", [DB.uuid(id)])
    Util.require!(meta != nil, "RESOURCE_NOT_FOUND")

    if meta["room_id"] == nil do
      Ruxi.ProductionJobs.dispatch(id, op, p, principal)
    else
      fields =
        ~w(attempt lease_token) ++
          case op do
            "complete" -> ~w(result_hash result)
            "fail" -> ~w(code retryable)
            _ -> []
          end

      RuxiWeb.Router.json!(p, fields)

      DB.transaction(fn ->
        # Room first, then work item: same lock order as deadline fallback.
        meta = DB.one("SELECT room_id FROM work_items WHERE id=$1", [DB.uuid(id)])
        Util.require!(meta != nil, "RESOURCE_NOT_FOUND")
        row = Store.load!(DB.str(meta["room_id"]), true)
        job = DB.one("SELECT * FROM work_items WHERE id=$1 FOR UPDATE", [DB.uuid(id)])

        Util.require!(
          job["leased_by"] == principal["worker_id"] and job["kind"] in principal["allowed_kinds"],
          "NOT_ALLOWED"
        )

        now = DB.time()

        if op == "complete" and job["completed_attempt"] == p["attempt"] do
          Util.require!(job["result_hash"] == p["result_hash"], "RESULT_CONFLICT")
          job["completion_response_json"]
        else
          Util.require!(
            job["status"] == "leased" and job["attempt"] == p["attempt"] and
              job["lease_hash"] == Util.hash(p["lease_token"] || "") and job["lease_until"] > now,
            "STALE_LEASE"
          )

          case op do
            "heartbeat" ->
              DB.query("UPDATE work_items SET lease_until=$2 WHERE id=$1", [
                job["id"],
                now + 60_000
              ])

              %{"lease_until" => Util.iso(now + 60_000), "cancel_requested" => false}

            "fail" ->
              Util.require!(
                is_boolean(p["retryable"]) and is_binary(p["code"]) and
                  String.length(p["code"]) in 1..64,
                "INVALID_ARGUMENT"
              )

              if p["retryable"] do
                DB.query("UPDATE work_items SET status='queued',lease_until=NULL WHERE id=$1", [
                  job["id"]
                ])
              else
                state = row["state_json"]
                mid = DB.str(job["member_id"])
                pending = Rules.member(state, mid)["hint_pending"]

                if pending && pending["reservation"] == job["basis"]["reservation_id"] do
                  updated = Rules.update_member(state, mid, &Map.put(&1, "hint_pending", nil))
                  Store.save(state, updated, "hint_failed", now)
                end

                DB.query("UPDATE work_items SET status='failed',lease_until=NULL WHERE id=$1", [
                  job["id"]
                ])
              end

              %{"status" => "failed"}

            "complete" ->
              result = p["result"]

              Util.require!(
                is_map(result) and Enum.sort(Map.keys(result)) == ~w(evidence_ids narrative) and
                  is_binary(result["narrative"]) and
                  String.length(String.trim(result["narrative"])) in 1..2000 and
                  is_list(result["evidence_ids"]) and length(result["evidence_ids"]) <= 100 and
                  Enum.all?(result["evidence_ids"], &is_binary/1),
                "INVALID_ARGUMENT"
              )

              Util.require!(p["result_hash"] == Util.hash(result), "RESULT_CONFLICT")
              s = row["state_json"]
              n = Rules.tick(s, now)
              mid = DB.str(job["member_id"])
              m = Rules.member(n, mid)

              eligible =
                n["phase_id"] == job["basis"]["phase_id"] and
                  Rules.knowledge_hash(n, mid) == job["basis"]["knowledge_hash"] and
                  m["hint_pending"] != nil and
                  m["hint_pending"]["reservation"] == job["basis"]["reservation_id"] and
                  Enum.all?(result["evidence_ids"], &(&1 in (m["known"] ++ n["shared"])))

              n =
                if eligible,
                  do:
                    Rules.finish_hint(
                      n,
                      mid,
                      job["basis"]["reservation_id"],
                      result["narrative"],
                      if(result["narrative"] == job["input_json"]["template"],
                        do: "template",
                        else: "ai"
                      )
                    ),
                  else: n

              if n != s, do: Store.save(s, n, "hint_ready", now)
              reply = %{"status" => if(eligible, do: "accepted", else: "ignored")}

              DB.query(
                "UPDATE work_items SET status='completed',result_hash=$2,result_json=$3,completion_response_json=$4,completed_attempt=$5 WHERE id=$1",
                [job["id"], p["result_hash"], result, reply, p["attempt"]]
              )

              reply
          end
        end
      end)
    end
  end

  def dispatch(_, _, _), do: Util.fail("INVALID_ARGUMENT")
end
