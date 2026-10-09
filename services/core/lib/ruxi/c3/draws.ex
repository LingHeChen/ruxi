defmodule Ruxi.C3.Draws do
  @moduledoc "Durable draw journal committed independently of the world transaction."
  alias Ruxi.{DB, Util}

  def with_room(room, fun) do
    previous = Process.get(:c3_draw_context)
    Process.put(:c3_draw_context, {DB.str(room["id"]), room["owner_epoch"]})

    try do
      fun.()
    after
      if previous,
        do: Process.put(:c3_draw_context, previous),
        else: Process.delete(:c3_draw_context)
    end
  end

  def sample do
    <<n::unsigned-big-32>> = :crypto.strong_rand_bytes(4)
    if n < 4_294_967_200, do: rem(n, 100) + 1, else: sample()
  end

  def draw(s, id) do
    case Process.get(:c3_draw_context) do
      {room, epoch} ->
        step = s["step_id"]

        task =
          Task.async(fn ->
            # The caller holds the room lock. This connection commits before world effects.
            roll = sample()

            DB.query(
              "INSERT INTO c3_resolution_draws(room_id,step_id,intent_id,draw_slot,roll,algorithm_version,owner_epoch,created_at) SELECT $1,$2,$3,0,$4,'crypto-rejection-v1',$5,$6 FROM c2_rooms WHERE id=$1 AND owner_epoch=$5 ON CONFLICT DO NOTHING",
              [DB.uuid(room), DB.uuid(step), DB.uuid(id), roll, epoch, DB.time()]
            )

            row =
              DB.one(
                "SELECT roll FROM c3_resolution_draws WHERE room_id=$1 AND step_id=$2 AND intent_id=$3 AND draw_slot=0",
                [DB.uuid(room), DB.uuid(step), DB.uuid(id)]
              )

            Util.require!(row != nil, "OWNER_UNAVAILABLE")
            row["roll"]
          end)

        Task.await(task, 5000)

      nil ->
        # Isolated author previews and pure engine fixtures have no persisted room.
        key = Base.decode64!(s["random_key"])
        <<n::unsigned-big-64, _::binary>> = :crypto.mac(:hmac, :sha256, key, id)
        rem(n, 100) + 1
    end
  end
end
