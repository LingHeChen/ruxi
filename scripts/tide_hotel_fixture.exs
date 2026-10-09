alias Ruxi.C2.Engine
s = File.read!("../../content/c3/tide_hotel/story.json") |> Jason.decode!() |> Engine.initial(0)

s =
  Enum.reduce(s["cues"], s, fn c, a ->
    {:ok, n, _} =
      Engine.command(
        a,
        "reporter",
        "media.complete",
        %{"cue_id" => c["id"], "mode" => "summary"},
        Ruxi.Util.id(),
        1
      )

    n
  end)

v =
  Engine.project(s, "reporter", 1)
  |> Map.merge(%{
    "story_title" => "潮汐旅馆：第九声钟响",
    "roles" => [%{"id" => "reporter", "label" => "徐闻 · 声音记者"}],
    "members" => [
      %{
        "member_id" => "fixture",
        "role_id" => "reporter",
        "display_name" => "徐闻",
        "ready" => true
      }
    ],
    "own_member_id" => "fixture",
    "host_member_id" => "fixture"
  })

File.write!(
  "../../apps/mobile/test/fixtures/tide_hotel_view.json",
  Jason.encode!(
    %{
      "protocol_version" => 3,
      "stream_id" => "fixture",
      "view_seq" => 1,
      "control_epoch" => 1,
      "blocks" => v
    }, pretty: true)
)
