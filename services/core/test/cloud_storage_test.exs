defmodule Ruxi.CloudStorageTest do
  use ExUnit.Case, async: false
  alias Ruxi.{CloudStorage, Objects, Util}

  setup do
    vars = ~w(OBJECT_BACKEND OBJECT_ROOT CLOUDBASE_STORAGE_BUCKET)
    old = Map.new(vars, &{&1, System.get_env(&1)})
    transport = Application.get_env(:ruxi, :cloud_storage_transport)
    root = Path.join(System.tmp_dir!(), "ruxi-cloud-test-" <> Util.id())
    System.put_env("OBJECT_BACKEND", "cloudbase")
    System.put_env("OBJECT_ROOT", root)
    System.put_env("CLOUDBASE_STORAGE_BUCKET", "ruxi-private")

    on_exit(fn ->
      for {key, value} <- old do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      if transport,
        do: Application.put_env(:ruxi, :cloud_storage_transport, transport),
        else: Application.delete_env(:ruxi, :cloud_storage_transport)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "objects survive loss of container cache and cannot be overwritten", %{root: root} do
    {:ok, state} = Agent.start_link(fn -> %{} end)

    Application.put_env(:ruxi, :cloud_storage_transport, fn method, path, body, _ ->
      Agent.get_and_update(state, fn objects ->
        case {method, Map.fetch(objects, path)} do
          {:post, :error} -> {{200, "{}"}, Map.put(objects, path, body)}
          {:post, {:ok, _}} -> {{409, "{}"}, objects}
          {:get, {:ok, bytes}} -> {{200, bytes}, objects}
          {:get, :error} -> {{404, "{}"}, objects}
          {:delete, _} -> {{200, "{}"}, Map.delete(objects, path)}
        end
      end)
    end)

    key = "ruxi/assets/test/source.bin"
    Objects.put!(key, "evidence", Util.hash("evidence"))
    File.rm_rf!(root)
    assert File.read!(Objects.verify!(key, 8, Util.hash("evidence"))) == "evidence"

    assert catch_throw(Objects.put!(key, "changed!", Util.hash("changed!"))) ==
             {:error, "ASSET_MISMATCH"}

    Objects.copy!(key, "ruxi/assets/test/copy.bin")
    File.rm_rf!(root)
    assert File.read!(Objects.path("ruxi/assets/test/copy.bin")) == "evidence"
    :ok = Objects.delete!(key)
    refute File.regular?(Objects.path(key))
  end

  test "ledger listing follows all pages and rejects repeated cursors" do
    Application.put_env(:ruxi, :cloud_storage_transport, fn :post, _, body, _ ->
      case Jason.decode!(body)["cursor"] do
        nil ->
          {200,
           Jason.encode!(%{
             "objects" => [%{"key" => "ruxi/erasure-ledger/a.json"}],
             "nextCursor" => "page2"
           })}

        "page2" ->
          {200, Jason.encode!(%{"objects" => [%{"key" => "ruxi/erasure-ledger/b.json"}]})}
      end
    end)

    assert CloudStorage.list!("ruxi/erasure-ledger/") == [
             "ruxi/erasure-ledger/a.json",
             "ruxi/erasure-ledger/b.json"
           ]

    Application.put_env(:ruxi, :cloud_storage_transport, fn _, _, _, _ ->
      {200, Jason.encode!(%{"objects" => [], "nextCursor" => "loop"})}
    end)

    assert catch_throw(CloudStorage.list!("ruxi/erasure-ledger/")) ==
             {:error, "SERVICE_UNAVAILABLE"}
  end

  test "storage failure cannot acknowledge account erasure or empty replay" do
    Application.put_env(:ruxi, :cloud_storage_transport, fn _, _, _, _ -> {503, "{}"} end)

    record = %{
      "schema" => 1,
      "user_id" => Util.id(),
      "request_id" => Util.id(),
      "erased_at" => Util.now()
    }

    assert catch_throw(Ruxi.Privacy.append(record)) == {:error, "SERVICE_UNAVAILABLE"}
    assert catch_throw(Ruxi.Privacy.replay()) == {:error, "SERVICE_UNAVAILABLE"}
  end
end
