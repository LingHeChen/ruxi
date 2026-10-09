# Prints provider status only, never headers, credentials or token material.
alias Ruxi.SceneVoice.VolcRtcGateway, as: Gateway
room="ruxi_probe_"<>Ruxi.Util.id()
body=Jason.encode!(%{"AppId"=>Gateway.app_id(),"RoomId"=>room,"ForbiddenInterval"=>180})
now=Calendar.strftime(DateTime.utc_now(),"%Y%m%dT%H%M%SZ")
{url,headers}=Gateway.signed_request(body,now,System.fetch_env!("VOLC_ACCESS_KEY_ID"),System.fetch_env!("VOLC_SECRET_ACCESS_KEY"))
request={String.to_charlist(url),Enum.map(headers,fn {k,v}->{String.to_charlist(k),String.to_charlist(v)} end),~c"application/json",body}
case :httpc.request(:post,request,[timeout: 6000,connect_timeout: 3000,ssl: [verify: :verify_peer, customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],cacerts: :public_key.cacerts_get()]],[body_format: :binary]) do
  {:ok,{{_,status,_},_,raw}} ->
    data=Jason.decode!(raw)
    IO.inspect(%{http_status: status,provider_code: get_in(data,["ResponseMetadata","Error","Code"]),result: get_in(data,["Result","Message"])})
  {:error, reason} -> IO.inspect(reason, limit: 50, printable_limit: 800)
end
