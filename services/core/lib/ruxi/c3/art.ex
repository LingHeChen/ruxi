defmodule Ruxi.C3.Art do
  @moduledoc "Publication gate for immutable images shipped in the player bundle. External media remains unavailable until project-bound storage is integrated."
  def publishable?(%{"kind" => "text"}), do: true

  def publishable?(%{"kind" => "image", "uri" => uri, "sha256" => digest}) do
    path = Application.app_dir(:ruxi, "priv/c3/bundled_art.json")

    with {:ok, bytes} <- File.read(path), {:ok, manifest} <- Jason.decode(bytes) do
      manifest[uri] == digest and is_binary(digest) and byte_size(digest) == 64
    else
      _ -> false
    end
  end

  def publishable?(_), do: false
end
