defmodule Ruxi.Contract do
  alias Ruxi.Util, as: U

  @payloads %{
    "select_role" => ["role_code"],
    "ready" => ["ready"],
    "start" => [],
    "media_complete" => ["media_id", "media_epoch", "mode"],
    "confirm_exploration_end" => [],
    "request_pause" => [],
    "confirm_pause" => ["pause_request_id"],
    "cancel_pause" => ["pause_request_id"],
    "resume" => ["timer_generation"],
    "leave_room" => [],
    "investigate" => ["action_id"],
    "share_clue" => ["clue_id"],
    "offer_item" => ["item_id", "to_member"],
    "accept_offer" => ["offer_id"],
    "reject_offer" => ["offer_id"],
    "cancel_offer" => ["offer_id"],
    "vote" => ["round_id", "option_id"],
    "request_hint" => ["hint_level"],
    "chat_send" => ["text"],
    "request_role_swap" => ["to_member"],
    "accept_role_swap" => ["role_swap_id"],
    "reject_role_swap" => ["role_swap_id"],
    "cancel_role_swap" => ["role_swap_id"]
  }
  def payloads, do: @payloads
  def uuid?(v), do: is_binary(v) and match?({:ok, _}, Ecto.UUID.cast(v))

  def command!(c) do
    fields =
      ~w(protocol_version command_id recovery_epoch phase_id control_generation type payload)

    allowed = if c["type"] == "offer_item", do: fields ++ ["target_version"], else: fields
    U.require!(is_map(c) and Enum.sort(Map.keys(c)) == Enum.sort(allowed), "INVALID_ARGUMENT")

    U.require!(
      c["protocol_version"] == 1 and uuid?(c["command_id"]) and
        (is_nil(c["phase_id"]) or uuid?(c["phase_id"])) and is_binary(c["recovery_epoch"]),
      "INVALID_ARGUMENT"
    )

    U.require!(
      is_integer(c["control_generation"]) and c["control_generation"] in 1..9_007_199_254_740_991,
      "INVALID_ARGUMENT"
    )

    p = c["payload"]
    expected = @payloads[c["type"]]

    U.require!(
      expected != nil and is_map(p) and Enum.sort(Map.keys(p)) == Enum.sort(expected),
      "INVALID_ARGUMENT"
    )

    U.require!(byte_size(Jason.encode!(c)) <= 16_384, "PAYLOAD_TOO_LARGE")

    for {k, v} <- p do
      cond do
        k in ~w(to_member offer_id round_id pause_request_id role_swap_id) ->
          U.require!(uuid?(v), "INVALID_ARGUMENT")

        k == "ready" ->
          U.require!(is_boolean(v), "INVALID_ARGUMENT")

        k in ~w(timer_generation media_epoch hint_level) ->
          U.require!(is_integer(v) and v >= 0 and v <= 9_007_199_254_740_991, "INVALID_ARGUMENT")

        true ->
          U.require!(
            is_binary(v) and String.length(v) <= if(k == "text", do: 500, else: 64),
            "INVALID_ARGUMENT"
          )
      end
    end

    if c["type"] == "offer_item",
      do:
        U.require!(
          is_integer(c["target_version"]) and c["target_version"] > 0,
          "INVALID_ARGUMENT"
        )

    c
  end

  def digest(c), do: c |> Map.drop(["control_generation"]) |> U.hash()
end
