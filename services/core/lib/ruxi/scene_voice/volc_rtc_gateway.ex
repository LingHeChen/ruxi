defmodule Ruxi.SceneVoice.VolcRtcGateway do
  @moduledoc "Formal room/UID-bound Volcengine v001 tokens and signed whole-room retirement."
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

  # Only the independently verified forced-expiry fallback is available. A Ban
  # acknowledgement on its own never commits a scene transition.
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

  def retire(room) do
    if ready?() do
      Ruxi.Limiter.check!(:volc_ban, 20, 20)
      body = Jason.encode!(%{"AppId" => app_id(), "RoomId" => room, "ForbiddenInterval" => 180})
      now = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")

      {url, headers} =
        signed_request(
          body,
          now,
          System.fetch_env!("VOLC_ACCESS_KEY_ID"),
          System.fetch_env!("VOLC_SECRET_ACCESS_KEY")
        )

      req =
        {String.to_charlist(url),
         Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
         ~c"application/json", body}

      case :httpc.request(
             :post,
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
            {:ok, %{"ResponseMetadata" => metadata, "Result" => %{"Message" => "success"}}}
            when not is_map_key(metadata, "Error") ->
              :accepted

            _ ->
              :unknown
          end

        _ ->
          :unknown
      end
    else
      :unknown
    end
  end

  def signed_request(body, now, access, secret) do
    host = "rtc.volcengineapi.com"
    query = "Action=BanRoomUser&Version=2023-11-01"
    hash = Util.hash(body)

    headers = [
      {"content-type", "application/json"},
      {"host", host},
      {"x-content-sha256", hash},
      {"x-date", now}
    ]

    names = Enum.map_join(headers, ";", &elem(&1, 0))
    canon = Enum.map_join(headers, "", fn {k, v} -> k <> ":" <> v <> "\n" end)
    canonical = "POST\n/\n" <> query <> "\n" <> canon <> "\n" <> names <> "\n" <> hash
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
