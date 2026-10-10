defmodule Ruxi.Objects do
  @moduledoc "Immutable objects with a local adapter or CloudBase-backed local cache."
  alias Ruxi.{Util, CloudStorage}
  def root, do: System.get_env("OBJECT_ROOT", Path.expand("../../.local/objects", File.cwd!()))

  def path(key) do
    Util.require!(
      is_binary(key) and Regex.match?(~r/\Aruxi\/[a-z0-9\/-]+\.[a-z0-9]+\z/, key) and
        not String.contains?(key, ".."),
      "INVALID_ARGUMENT"
    )

    target = Path.join(root(), key)

    if CloudStorage.enabled?() and not File.regular?(target) do
      case CloudStorage.get(key) do
        {200, bytes} ->
          File.mkdir_p!(Path.dirname(target))
          temp = target <> "." <> Util.id()
          File.write!(temp, bytes, [:binary, :exclusive])
          File.chmod!(temp, 0o600)
          commit_cache!(temp, target, byte_size(bytes), Util.hash(bytes))

        {404, _} ->
          :ok

        _ ->
          Util.fail("SERVICE_UNAVAILABLE")
      end
    end

    target
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

    try do
      commit!(temp, target, byte_size(bytes), sha)
    after
      File.rm(temp)
    end

    target
  end

  def commit!(temp, target, size, sha) do
    Util.require!(File.stat!(temp).size == size and hash(temp) == sha, "ASSET_MISMATCH")

    if CloudStorage.enabled?() do
      key = Path.relative_to(target, root())

      Util.require!(
        String.starts_with?(key, "ruxi/") and not String.contains?(key, ".."),
        "INVALID_ARGUMENT"
      )

      CloudStorage.put!(key, File.read!(temp))
    end

    commit_cache!(temp, target, size, sha)
  end

  def copy!(source, target) do
    bytes = File.read!(path(source))
    put!(target, bytes, Util.hash(bytes))
  end

  def delete!(key) do
    if CloudStorage.enabled?(), do: CloudStorage.delete!(key)
    File.rm(Path.join(root(), key))
    :ok
  end

  defp commit_cache!(temp, target, size, sha) do
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
