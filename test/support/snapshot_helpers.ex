defmodule Crawler.SnapshotHelpers do
  @moduledoc false

  def saved_artifact(root, %{path: path}), do: Path.join(root, path)

  def link_path(href), do: href |> URI.parse() |> Map.fetch!(:path) |> URI.decode()
end
