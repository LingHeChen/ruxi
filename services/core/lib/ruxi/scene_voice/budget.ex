defmodule Ruxi.SceneVoice.Budget do
  alias Ruxi.DB
  def price, do: env_number("VOLC_RTC_PRICE_PER_PERSON_MINUTE", "0.007")
  def limit, do: env_number("VOLC_RTC_DAILY_BUDGET_YUAN", "50")

  defp env_number(key, default) do
    case Float.parse(System.get_env(key, default)) do
      {v, ""} when v >= 0 -> v
      _ -> raise ArgumentError, "invalid RTC budget configuration"
    end
  end

  def usage do
    now = DB.time()
    day = div(now, 86_400_000) * 86_400_000

    DB.one(
      "SELECT coalesce(sum(greatest(0,least(coalesce(u.left_at,$2),$2)-greatest(u.joined_at,$1))),0)::bigint AS ms FROM c2_voice_usage u WHERE u.left_at IS NULL OR u.left_at>$1",
      [day, now]
    )["ms"] / 60_000
  end

  def exhausted?, do: usage() * price() >= limit()

  def retire_due? do
    if exhausted?() do
      row =
        DB.one(
          "INSERT INTO c2_voice_budget_days(day,reached_at) VALUES(CURRENT_DATE,$1) ON CONFLICT(day) DO UPDATE SET reached_at=coalesce(c2_voice_budget_days.reached_at,$1) RETURNING reached_at",
          [DB.time()]
        )

      row["reached_at"] <= DB.time() - 60_000
    else
      false
    end
  end
end
