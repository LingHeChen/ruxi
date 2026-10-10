defmodule Ruxi.SceneVoice.VolcRtcGateway do
  @moduledoc "Room/UID-bound tokens with provider-confirmed room and member revocation."
  alias Ruxi.Util

  def configured?,
    do:
      Enum.all?(
        ~w(VOLC_RTC_APP_ID VOLC_RTC_APP_KEY VOLC_ACCESS_KEY_ID VOLC_SECRET_ACCESS_KEY),
        &(System.get_env(&1) not in [nil, ""])
      )

  # An acknowledgement is not a media fence. Keep issuance off until the deployed
  # provider/SDK combination has passed VA01 and its evidence is explicitly pinned.
  def ready? do
    evidence = Application.app_dir(:ruxi, "priv/voice/rtc-evidence.json")

    with true <- configured?(),
         id when is_binary(id) <- System.get_env("VOLC_RTC_FENCE_VERIFICATION_ID"),
         {:ok, bytes} <- File.read(evidence),
         {:ok, proof} <- Jason.decode(bytes) do
      proof["verification_id"] == id && proof["app_id_hash"] == Util.hash(app_id()) &&
        proof["forced_expiry_verified"] == true
    else
      _ -> false
    end
  end

  # Forced expiry remains the fallback when provider revocation cannot be confirmed.
  def expiry_fenced?(channel),
    do: ready?() && Util.now() >= channel["max_token_expires_at"] + 30_000

  def app_id, do: System.fetch_env!("VOLC_RTC_APP_ID")

  def token(room, uid, expires),
    do:
      encode_token(
        app_id(),
        System.fetch_env!("VOLC_RTC_APP_KEY"),
        room,
        uid,
        div(Util.now(), 1000),
        div(expires, 1000),
        :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned(:little)
      )

  # Wire format matches official AccessToken.java/ByteBuf.java (little endian).
  def encode_token(app, key, room, uid, issued, expiry, nonce) do
    Util.require!(room != "" and uid != "", "INPUT_INVALID")
    privileges = Enum.map_join(0..4, fn p -> <<p::little-16, expiry::little-32>> end)

    msg =
      <<nonce::little-32, issued::little-32, expiry::little-32>> <>
        pack(room) <> pack(uid) <> <<5::little-16>> <> privileges

    signature = :crypto.mac(:hmac, :sha256, key, msg)
    "001" <> app <> Base.encode64(pack(msg) <> pack(signature))
  end

  defp pack(bytes), do: <<byte_size(bytes)::little-16>> <> bytes

  # Require a successful timed ban and authoritative
  # absence. API acknowledgement alone never fences existing media.
  def revoke(room, uid, nil) do
    case ban(room, uid) do
      :accepted ->
        # Query immediately; presence is the completion signal, not a timer.
        case revoke(room, uid, Util.now()) do
          :fenced -> :fenced
          _ -> :accepted
        end

      other ->
        other
    end
  end

  def revoke(room, uid, _accepted_at) do
    with true <- ready?(),
         {:ok, bytes} <- File.read(Application.app_dir(:ruxi, "priv/voice/rtc-evidence.json")),
         {:ok, %{"ban_query_verified" => true}} <- Jason.decode(bytes),
         {:ok, users} <- online(room) do
      if (uid == nil && users == []) || (uid != nil && uid not in users),
        do: :fenced,
        else: :unknown
    else
      _ -> :unknown
    end
  end

  def retire(room), do: ban(room, nil)
  def retire_member(room, uid), do: ban(room, uid)

  defp ban(room, uid) do
    body = %{"AppId" => app_id(), "RoomId" => room, "ForbiddenInterval" => 600}
    body = if uid, do: Map.put(body, "UserId", uid), else: body

    with true <- ready?(),
         {:ok, %{"Message" => "success"}} <- api(:post, "BanRoomUser", body) do
      :accepted
    else
      _ -> :unknown
    end
  end

  def online(room) do
    with {:ok, result} <-
           api(:get, "GetRoomOnlineUsers", %{"AppId" => app_id(), "RoomId" => room}) do
      case result do
        %{"RoomExists" => false} ->
          {:ok, []}

        %{"RoomExists" => true, "TotalUser" => total} when is_integer(total) ->
          users = (result["VisibleUserList"] || []) ++ (result["InvisibleUserList"] || [])
          if length(users) == total, do: {:ok, users}, else: :unknown

        _ ->
          :unknown
      end
    else
      _ -> :unknown
    end
  end

  def api(method, action, params) do
    Ruxi.Limiter.check!(:volc_ban, 20, 20)
    body = if method == :post, do: Jason.encode!(params), else: ""
    query_params = if method == :get, do: params, else: %{}
    now = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    {url, headers} =
      signed_request(
        body,
        now,
        System.fetch_env!("VOLC_ACCESS_KEY_ID"),
        System.fetch_env!("VOLC_SECRET_ACCESS_KEY"),
        method,
        action,
        query_params
      )

    base =
      {String.to_charlist(url),
       Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}

    req =
      if method == :get,
        do: base,
        else: {elem(base, 0), elem(base, 1), ~c"application/json", body}

    case :httpc.request(
           method,
           req,
           [
             timeout: 6000,
             connect_timeout: 3000,
             ssl: [
               verify: :verify_peer,
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ],
               cacerts: :public_key.cacerts_get()
             ]
           ],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, response}} ->
        case Jason.decode(response) do
          {:ok, %{"ResponseMetadata" => metadata, "Result" => result}}
          when not is_map_key(metadata, "Error") ->
            {:ok, result}

          _ ->
            :unknown
        end

      _ ->
        :unknown
    end
  end

  def signed_request(
        body,
        now,
        access,
        secret,
        method \\ :post,
        action \\ "BanRoomUser",
        params \\ %{}
      ) do
    host = "rtc.volcengineapi.com"

    query =
      params
      |> Map.merge(%{"Action" => action, "Version" => "2023-11-01"})
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} ->
        URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v)
      end)

    hash = Util.hash(body)

    headers = [
      {"content-type", "application/json"},
      {"host", host},
      {"x-content-sha256", hash},
      {"x-date", now}
    ]

    names = Enum.map_join(headers, ";", &elem(&1, 0))
    canon = Enum.map_join(headers, "", fn {k, v} -> k <> ":" <> v <> "\n" end)

    canonical =
      String.upcase(to_string(method)) <>
        "\n/\n" <> query <> "\n" <> canon <> "\n" <> names <> "\n" <> hash

    date = String.slice(now, 0, 8)
    scope = date <> "/cn-north-1/rtc/request"

    key =
      Enum.reduce([date, "cn-north-1", "rtc", "request"], secret, fn text, k ->
        :crypto.mac(:hmac, :sha256, k, text)
      end)

    signature =
      :crypto.mac(
        :hmac,
        :sha256,
        key,
        "HMAC-SHA256\n" <> now <> "\n" <> scope <> "\n" <> Util.hash(canonical)
      )
      |> Base.encode16(case: :lower)

    {"https://" <> host <> "/?" <> query,
     headers ++
       [
         {"authorization",
          "HMAC-SHA256 Credential=" <>
            access <> "/" <> scope <> ", SignedHeaders=" <> names <> ", Signature=" <> signature}
       ]}
  end
end
