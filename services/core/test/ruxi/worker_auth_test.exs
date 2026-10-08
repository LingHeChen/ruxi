defmodule Ruxi.WorkerAuthTest do
  use ExUnit.Case, async: true

  test "worker token binds service identity and permitted task kinds without exposing credentials" do
    credentials = [
      %{"worker_id" => "hint-1", "token" => "test-hint-key", "allowed_kinds" => ["player_hint"]},
      %{
        "worker_id" => "media-1",
        "token" => "test-media-key",
        "allowed_kinds" => ["media_transcode"]
      }
    ]

    assert Ruxi.WorkerAuth.authenticate("test-hint-key", credentials) == %{
             "worker_id" => "hint-1",
             "allowed_kinds" => ["player_hint"]
           }

    assert Ruxi.WorkerAuth.authenticate("test-media-key", credentials) == %{
             "worker_id" => "media-1",
             "allowed_kinds" => ["media_transcode"]
           }

    assert catch_throw(Ruxi.WorkerAuth.authenticate("unknown", credentials)) ==
             {:error, "UNAUTHORIZED"}

    assert catch_throw(Ruxi.WorkerAuth.authenticate(nil, credentials)) == {:error, "UNAUTHORIZED"}
  end
end
