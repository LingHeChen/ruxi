defmodule Ruxi.C3.Interactions do
  @moduledoc "C3 interaction quotes and server-only password/check execution."
  alias Ruxi.{Util, Auth}
  alias Ruxi.C2.{Content, Engine, Schema}
  def enabled?(s), do: s["schema_version"] == 4
  def profile(s), do: s["c3"] || %{}
  def definitions(s), do: profile(s)["interactions"] || []

  def error(code, pointer),
    do: %{"code" => code, "pointer" => pointer, "message" => "C3 配置缺失或引用不合法"}

  def validate(s) do
    report = %{"errors" => Content.validate_c3_base(s)}

    schema =
      Application.app_dir(:ruxi, "priv/c3/extension.schema.json")
      |> File.read!()
      |> Jason.decode!()

    errors = report["errors"] ++ Schema.validate(s["c3"], schema)
    errors = if errors == [], do: semantic(s) ++ Ruxi.C3.Validation.validate(s), else: errors

    %{
      "valid" => errors == [],
      "errors" => errors,
      "schema_version" => 4,
      "hash" => if(errors == [], do: Util.hash(s), else: nil)
    }
  end

  defp semantic(s) do
    ids = Enum.map(definitions(s), & &1["id"])

    duplicate =
      if Enum.uniq(ids) == ids, do: [], else: [error("DUPLICATE_ID", "/c3/interactions")]

    duplicate ++
      Enum.flat_map(Enum.with_index(definitions(s)), fn {i, n} ->
        p = "/c3/interactions/#{n}"
        object = Content.index(s, "objects")[i["target_id"]]
        secret = (s["secrets"] || %{})[i["answer_secret_ref"]]

        []
        |> issue(is_nil(object), "UNKNOWN_REFERENCE", p <> "/target_id")
        |> issue(
          i["kind"] == "password" and (not is_map(secret) or not is_binary(secret["answer"])),
          "MISSING_SECRET",
          p <> "/answer_secret_ref"
        )
        |> issue(
          i["kind"] == "password" and i["min_length"] > i["max_length"],
          "INPUT_INVALID",
          p
        )
        |> Kernel.++(
          Enum.flat_map(i["on_success"] ++ i["on_failure"], fn e ->
            valid =
              case e["op"] do
                "set_flag" ->
                  Map.has_key?(s["initial"]["world"], e["ref"]) and
                    is_boolean(e["value"]) == is_boolean(s["initial"]["world"][e["ref"]])

                "grant_item" ->
                  Map.has_key?(Content.index(s, "objects"), e["ref"])

                "reveal" ->
                  Map.has_key?(Content.index(s, "clues"), e["ref"])

                "set_barrier" ->
                  e["value"] in ~w(open blocked destroyed) and
                    Map.has_key?(get_in(s, ["c3_settings", "barriers"]) || %{}, e["ref"])

                "reset_attempts" ->
                  e["ref"] in ids

                "leave_trace" ->
                  Map.has_key?(Content.index(s, "clues"), e["ref"])

                "set_membership" ->
                  Map.has_key?(Content.index(s, "roles"), e["ref"]) and
                    e["value"] in (get_in(s, ["c3_settings", "factions"]) || [])

                _ ->
                  false
              end

            if valid, do: [], else: [error("UNKNOWN_REFERENCE", p)]
          end)
        )
      end)
  end

  defp issue(es, true, c, p), do: es ++ [error(c, p)]
  defp issue(es, _, _, _), do: es

  def init(s) do
    if enabled?(s["content"]),
      do:
        Map.merge(s, %{
          "engine_version" => 3,
          "protocol_version" => 3,
          "quotes" => %{},
          "attempts" => %{},
          "solved" => [],
          "interaction_results" => [],
          "barriers" => get_in(s, ["content", "c3_settings", "barriers"]) || %{}
        }),
      else: s
  end

  defp require!(true, _), do: :ok
  defp require!(_, code), do: throw({:c2, code})
  def normalize(text, "exact"), do: text

  def normalize(text, "nfkc_trim_casefold"),
    do:
      text
      |> :unicode.characters_to_nfkc_binary()
      |> String.trim()
      |> String.to_charlist()
      |> :string.casefold()
      |> List.to_string()

  def valid_input?(i, answer) when is_binary(answer) do
    normalized = normalize(answer, i["normalization"])
    count = length(String.codepoints(normalized))

    byte_size(answer) <= 512 and count >= i["min_length"] and count <= i["max_length"] and
      not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, answer) and
      (i["format"] != "pin" or Regex.match?(~r/\A[0-9]+\z/, answer))
  end

  def valid_input?(_, _), do: false

  defp scope(i, r),
    do: i["id"] <> ":" <> if(i["attempts"]["scope"] == "room", do: "room", else: r)

  def counter(s, i, r),
    do: (s["attempts"] || %{})[scope(i, r)] || %{"used" => 0, "blocked_until_round" => 0}

  def available?(s, i, r) do
    obj = Content.index(s["content"], "objects")[i["target_id"]]
    a = s["actors"][r]
    c = counter(s, i, r)

    roles = get_in(s, ["content", "c3_settings", "interaction_roles", i["id"]])

    grants_available =
      Enum.all?(i["on_success"] ++ i["on_failure"], fn e ->
        e["op"] != "grant_item" or is_nil(s["ownership"][e["ref"]])
      end)

    grants_available and (roles == nil or r in roles) and obj != nil and a != nil and
      obj["location"] == a["location"] and
      i["id"] not in (s["solved"] || []) and c["used"] < i["attempts"]["max"] and
      s["round"] >= c["blocked_until_round"]
  end

  def target(s, i, r, now) do
    mods = Enum.filter(i["modifiers"], &condition(s, &1["when"], r, now))

    {max(0, min(100, i["base_target"] + Enum.sum(Enum.map(mods, & &1["delta"])))),
     Enum.map(mods, &Map.take(&1, ~w(label delta)))}
  end

  def condition(_, %{"op" => "always"}, _, _), do: true
  def condition(s, %{"op" => "known", "ref" => ref}, r, _), do: ref in s["actors"][r]["knowledge"]

  def condition(s, %{"op" => "eq", "ref" => "role", "value" => v}, r, _),
    do: s["actors"][r] != nil and r == v

  def condition(s, %{"op" => "eq", "ref" => ref, "value" => v}, r, now) do
    if String.starts_with?(ref, "world.") or String.starts_with?(ref, "actor.") or
         ref == "clock.round",
       do: Engine.condition(s, %{"op" => "eq", "ref" => ref, "value" => v}, r, now),
       else: s["barriers"][ref] == v
  end

  def dependency(s, i, r, now) do
    # Only modifiers actually read by this interaction contribute to the quote.
    Util.hash(%{
      "location" => s["actors"][r]["location"],
      "target" => i["target_id"],
      "modifiers" => Enum.map(i["modifiers"] || [], &condition(s, &1["when"], r, now))
    })
  end

  def quote(s, r, id, now) do
    try do
      i = Enum.find(definitions(s["content"]), &(&1["id"] == id))
      require!(i != nil and available?(s, i, r), "TARGET_UNAVAILABLE")

      require!(
        s["status"] == "active" and s["phase"] == "planning" and now < s["deadline"],
        "STEP_CLOSED"
      )

      require!(is_nil(s["intents"][r]), "STEP_CLOSED")
      {target, mods} = if i["kind"] == "check", do: target(s, i, r, now), else: {nil, []}

      q = %{
        "quote_id" => Util.id(),
        "interaction_id" => id,
        "kind" => i["kind"],
        "actor" => r,
        "step_id" => s["step_id"],
        "cost" => i["cost"],
        "target" => target,
        "modifiers" => mods,
        "dependency" => dependency(s, i, r, now),
        "expires_at" => min(now + 60_000, s["deadline"]),
        "used" => false,
        "attempts_remaining" => i["attempts"]["max"] - counter(s, i, r)["used"],
        "risk_text" =>
          get_in(s, ["content", "c3_settings", "interaction_labels", id, "risk_text"]) ||
            "尝试会消耗余力，失败也会计入次数。"
      }

      q =
        if i["kind"] == "password",
          do:
            Map.put(q, "input_spec", Map.take(i, ~w(format normalization min_length max_length))),
          else:
            Map.put(q, "check_preview", %{
              "target" => target,
              "base_target" => i["base_target"],
              "modifiers" => mods,
              "formula" => "1d100_lte"
            })

      quotes =
        s["quotes"]
        |> Enum.reject(fn {_, old} ->
          old["actor"] == r and old["interaction_id"] == id and not old["used"]
        end)
        |> Map.new()
        |> Map.put(q["quote_id"], q)

      {:ok, Map.put(s, "quotes", quotes), Map.drop(q, ~w(actor dependency used target modifiers))}
    catch
      {:c2, c} -> {:error, c, s}
    end
  end

  def submit(s, r, b, now) do
    q = s["quotes"][b["quote_id"]]
    require!(q != nil and q["actor"] == r, "TARGET_UNAVAILABLE")
    require!(not q["used"], "QUOTE_USED")
    require!(q["expires_at"] > now, "QUOTE_EXPIRED")
    require!(q["step_id"] == s["step_id"], "STEP_CLOSED")
    i = Enum.find(definitions(s["content"]), &(&1["id"] == q["interaction_id"]))
    require!(available?(s, i, r), "TARGET_UNAVAILABLE")
    require!(b["kind"] == i["kind"], "INPUT_INVALID")
    require!(q["dependency"] == dependency(s, i, r, now), "QUOTE_STALE")
    require!(is_nil(s["intents"][r]), "STEP_CLOSED")
    input = b["input"]
    require!(is_map(input), "INPUT_INVALID")

    require!(
      if(i["kind"] == "password",
        do: Map.keys(input) == ["answer"] and valid_input?(i, input["answer"]),
        else: map_size(input) == 0
      ),
      "INPUT_INVALID"
    )

    obj = Content.index(s["content"], "objects")[i["target_id"]]

    action = %{
      "id" => "interaction:" <> i["id"],
      "label" => label(s, i),
      "target" => i["target_id"],
      "location" => obj["location"],
      "cost" => i["cost"],
      "condition" => %{"op" => "all", "args" => []},
      "effects" => [],
      "failure" => [],
      "max_uses" => nil,
      "required_participants" => 1,
      "interaction" => i["id"],
      "quote_id" => q["quote_id"]
    }

    encrypted =
      if i["kind"] == "password",
        do: Base.encode64(Auth.seal(%{"answer" => input["answer"]})),
        else: nil

    {put_in(s, ["quotes", q["quote_id"], "used"], true), action, encrypted}
  end

  def label(s, i),
    do:
      get_in(s, ["content", "c3_settings", "interaction_labels", i["id"], "label"]) ||
        Content.index(s["content"], "objects")[i["target_id"]]["label"]

  def valid_action?(s, r, a, now) do
    if a["interaction"] do
      i = Enum.find(definitions(s["content"]), &(&1["id"] == a["interaction"]))
      available?(s, i, r) and s["quotes"][a["quote_id"]]["dependency"] == dependency(s, i, r, now)
    else
      true
    end
  end

  def execute(s, r, a, intent, _now) do
    i = Enum.find(definitions(s["content"]), &(&1["id"] == a["interaction"]))
    q = s["quotes"][a["quote_id"]]
    roll = if i["kind"] == "check", do: Ruxi.C3.Draws.draw(s, intent["id"]), else: nil

    success =
      if i["kind"] == "check" do
        roll <= q["target"]
      else
        secret = s["content"]["secrets"][i["answer_secret_ref"]]

        answer =
          Auth.unseal(Base.decode64!(intent["answer_cipher"]))["answer"]
          |> normalize(i["normalization"])

        Enum.any?(
          [secret["answer"] | secret["aliases"] || []],
          &Plug.Crypto.secure_compare(
            fingerprint(normalize(&1, i["normalization"])),
            fingerprint(answer)
          )
        )
      end

    c = counter(s, i, r) |> Map.update!("used", &(&1 + 1))

    result = %{
      "resolution_id" => intent["id"],
      "interaction_id" => i["id"],
      "kind" => i["kind"],
      "success" => success,
      "outcome" => if(success, do: "success", else: "failure"),
      "roll" => roll,
      "target" => q["target"],
      "attempts_remaining" => max(0, i["attempts"]["max"] - c["used"]),
      "actor" => r,
      "cost" => i["cost"],
      "image_uri" => Engine.image_uri(s["content"], "item_" <> i["target_id"], r)
    }

    s =
      s
      |> put_in(["attempts", scope(i, r)], c)
      |> Map.update!("interaction_results", &(&1 ++ [result]))

    s =
      if success and i["kind"] == "password",
        do: Map.update!(s, "solved", &[i["id"] | &1]),
        else: s

    {s, success, roll,
     Enum.map(if(success, do: i["on_success"], else: i["on_failure"]), &translate/1)}
  end

  def translate(%{"op" => "set_flag", "ref" => r, "value" => v}),
    do: %{"op" => "set", "ref" => "world." <> r, "value" => v}

  def translate(%{"op" => "grant_item", "ref" => r}), do: %{"op" => "grant", "ref" => r}

  def translate(%{"op" => op, "ref" => r}) when op in ~w(reveal leave_trace),
    do: %{"op" => "reveal", "ref" => r, "audience" => "self"}

  def translate(e), do: e

  def fingerprint(data) do
    key = Application.get_env(:ruxi, RuxiWeb.Endpoint)[:secret_key_base]
    :crypto.mac(:hmac, :sha256, key, Util.canonical(data)) |> Base.encode16(case: :lower)
  end

  def project(s, r) do
    definitions(s["content"])
    |> Enum.filter(&available?(s, &1, r))
    |> Enum.map(fn i ->
      %{
        "id" => i["id"],
        "label" => label(s, i),
        "kind" => i["kind"],
        "cost" => i["cost"],
        "target_id" => i["target_id"],
        "image_uri" => Engine.image_uri(s["content"], "item_" <> i["target_id"], r)
      }
    end)
  end
end
