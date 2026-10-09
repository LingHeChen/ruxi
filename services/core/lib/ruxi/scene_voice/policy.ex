defmodule Ruxi.SceneVoice.Policy do
  @moduledoc "Voice requires the engine's symmetric same-location presence projection."
  def validate(s) do
    if get_in(s, ["communication", "voice", "enabled"]) == true do
      for {location, index} <- Enum.with_index(s["locations"] || []),
          get_in(location, ["voice", "mode"]) != "disabled",
          not symmetric?(s, location),
          do: %{
            "code" => "VOICE_VISIBILITY_UNPROVEN",
            "pointer" => "/locations/#{index}/voice",
            "message" => "此场景无法证明玩家两两可见，请禁用场景语音"
          }
    else
      []
    end
  end

  defp symmetric?(s, l) do
    # Current engine publishes all co-located active player roles symmetrically.
    # Future custom presence/hiding rules are denied rather than inferred safe.
    s["schema_version"] in [3, 4] and is_nil(l["presence_condition"]) and
      is_nil(get_in(s, ["c3_settings", "presence_rules"])) and
      is_nil(get_in(s, ["c3_settings", "hidden_roles"]))
  end
end
