defmodule Ruxi.Objects do
  @moduledoc "Immutable local object adapter. Production requires a durable mounted root."
  alias Ruxi.Util
  def root, do: System.get_env("OBJECT_ROOT", Path.expand("../../.local/objects", File.cwd!()))

  def path(key) do
    Util.require!(
      is_binary(key) and Regex.match?(~r/\Aruxi\/[a-z0-9\/-]+\.[a-z0-9]+\z/, key) and
        not String.contains?(key, ".."),
      "INVALID_ARGUMENT"
    )

    Path.join(root(), key)
  end

  def hash(path),
    do:
      File.stream!(path, 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

  def verify!(key, size, sha) do
    file = path(key)

    Util.require!(
      File.regular?(file) and File.stat!(file).size == size and hash(file) == sha,
      "ASSET_MISMATCH"
    )

    file
  end

  def put!(key, bytes, sha) do
    target = path(key)
    File.mkdir_p!(Path.dirname(target))
    Util.require!(Util.hash(bytes) == sha, "ASSET_MISMATCH")
    temp = target <> "." <> Util.id()
    File.write!(temp, bytes, [:binary, :exclusive])
    File.chmod!(temp, 0o600)
    commit!(temp, target, byte_size(bytes), sha)
    target
  end

  def commit!(temp, target, size, sha) do
    try do
      Util.require!(File.stat!(temp).size == size and hash(temp) == sha, "ASSET_MISMATCH")

      case File.ln(temp, target) do
        :ok ->
          :ok

        {:error, :eexist} ->
          Util.require!(File.stat!(target).size == size and hash(target) == sha, "ASSET_MISMATCH")

        {:error, _} ->
          Util.fail("SERVICE_UNAVAILABLE")
      end
    after
      File.rm(temp)
    end
  end
end
