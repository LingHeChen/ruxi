defmodule Ruxi.EditorAI do
  alias Ruxi.{DB, Util, Auth, Objects}

  def create(ctx, id, p) do
    RuxiWeb.Router.json!(p, ~w(command_id revision target instruction), ~w(media_id))
    Auth.role!(ctx, "editor")

    Util.require!(
      is_binary(p["instruction"]) and String.length(p["instruction"]) in 1..500,
      "INVALID_ARGUMENT"
    )

    Auth.account(ctx, "editor.ai.create", Map.put(p, "version_id", id), fn ->
      v = DB.one("SELECT * FROM content_versions WHERE id=$1 FOR UPDATE", [DB.uuid(id)])
      Util.require!(v != nil and v["status"] != "published", "NOT_ALLOWED")
      Util.require!(v["revision"] == p["revision"], "REVISION_CONFLICT")

      path =
        case p["target"] do
          "title" ->
            ["title"]

          "description" ->
            ["description"]

          "asset_summary" ->
            index = Enum.find_index(v["graph"]["assets"], &(&1["media_id"] == p["media_id"]))
            Util.require!(index != nil, "INVALID_ARGUMENT")
            ["assets", index, "summary"]

          _ ->
            Util.fail("INVALID_ARGUMENT")
        end

      input = %{
        "target" => path,
        "original" => get_in(v["graph"], access(path)) || "",
        "instruction" => p["instruction"],
        "max_length" => if(p["target"] == "title", do: 120, else: 2000)
      }

      basis = %{
        "version_id" => id,
        "revision" => v["revision"],
        "content_hash" => v["content_hash"]
      }

      job = Util.id()

      DB.query(
        "INSERT INTO work_items(id,created_by,kind,input_json,basis,status,created_at) VALUES($1,$2,'editor_ai',$3,$4,'queued',$5)",
        [DB.uuid(job), DB.uuid(ctx.user), input, basis, DB.time()]
      )

      %{"job_id" => job, "status" => "queued"}
    end)
  end

  def get(ctx, id) do
    Auth.role!(ctx, "editor")

    j =
      DB.one("SELECT * FROM work_items WHERE id=$1 AND kind='editor_ai' AND created_by=$2", [
        DB.uuid(id),
        DB.uuid(ctx.user)
      ])

    Util.require!(j != nil, "RESOURCE_NOT_FOUND")

    %{
      "job_id" => id,
      "status" => j["status"],
      "outcome" => j["completion_response_json"],
      "proposal" => get_in(j, ["completion_response_json", "proposal"])
    }
  end

  def complete!(j, v, r) do
    RuxiWeb.Router.json!(r, ~w(proposal_ref sha256))
    key = "ruxi/jobs/#{DB.str(j["id"])}/#{j["attempt"]}/proposal.json"

    Util.require!(
      r["proposal_ref"] == key and Ruxi.Assets.digest?(r["sha256"]),
      "INVALID_ARGUMENT"
    )

    file = Objects.path(key)

    Util.require!(
      File.regular?(file) and File.stat!(file).size <= 65_536 and
        Objects.hash(file) == r["sha256"],
      "ASSET_MISMATCH"
    )

    p = File.read!(file) |> Ruxi.StrictJSON.decode!()
    RuxiWeb.Router.json!(p, ~w(schema_version target original suggested notes source))

    Util.require!(
      p["schema_version"] == 1 and p["target"] == j["input_json"]["target"] and
        p["original"] == j["input_json"]["original"] and is_binary(p["suggested"]) and
        String.length(String.trim(p["suggested"])) in 1..j["input_json"]["max_length"] and
        is_list(p["notes"]) and length(p["notes"]) <= 5 and
        Enum.all?(p["notes"], &(is_binary(&1) and String.length(&1) <= 200)) and
        p["source"] in ~w(ai template),
      "INVALID_ARGUMENT"
    )

    eligible =
      v["revision"] == j["basis"]["revision"] and v["content_hash"] == j["basis"]["content_hash"] and
        v["status"] != "published"

    %{"status" => if(eligible, do: "accepted", else: "ignored"), "proposal" => p}
  end

  def apply(ctx, id, p) do
    RuxiWeb.Router.json!(p, ~w(command_id revision))
    Auth.role!(ctx, "editor")

    Auth.account(ctx, "editor.ai.apply", Map.put(p, "job_id", id), fn ->
      j =
        DB.one("SELECT * FROM work_items WHERE id=$1 AND created_by=$2 AND kind='editor_ai'", [
          DB.uuid(id),
          DB.uuid(ctx.user)
        ])

      Util.require!(
        j != nil and j["status"] == "completed" and
          j["completion_response_json"]["status"] == "accepted",
        "NOT_ALLOWED"
      )

      v =
        DB.one("SELECT * FROM content_versions WHERE id=$1 FOR UPDATE", [
          DB.uuid(j["basis"]["version_id"])
        ])

      Util.require!(
        v["status"] != "published" and v["revision"] == p["revision"] and
          v["revision"] == j["basis"]["revision"] and
          v["content_hash"] == j["basis"]["content_hash"],
        "REVISION_CONFLICT"
      )

      proposal = j["completion_response_json"]["proposal"]
      g = put_in(v["graph"], access(proposal["target"]), proposal["suggested"])
      Util.require!(Ruxi.ContentAST.compile(g)["valid"], "CONTENT_INVALID")
      hash = Util.hash(g)

      DB.query(
        "UPDATE content_versions SET graph=$2,content_hash=$3,revision=revision+1,status='draft',validation=NULL,approved_hash=NULL WHERE id=$1",
        [v["id"], g, hash]
      )

      DB.query(
        "INSERT INTO audit_log(id,user_id,operation,target_id,occurred_at) VALUES($1,$2,'editor.ai.apply',$3,$4)",
        [DB.uuid(Util.id()), DB.uuid(ctx.user), v["id"], DB.time()]
      )

      %{"revision" => v["revision"] + 1, "hash" => hash, "version_id" => DB.str(v["id"])}
    end)
  end

  defp access(path),
    do: Enum.map(path, fn p -> if is_integer(p), do: Access.at(p), else: Access.key(p) end)
end
