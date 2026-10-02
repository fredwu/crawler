defmodule Crawler.SnapshotHelpers do
  @moduledoc false

  import ExUnit.Assertions

  alias Crawler.Linker
  alias Crawler.Linker.Snapshot

  def saved(root, url), do: Path.join(root, Snapshot.path(url))

  def link_path(href), do: href |> URI.parse() |> Map.fetch!(:path) |> URI.decode()

  def assert_link_opens(root, from_url, to_url) do
    body = File.read!(saved(root, from_url))
    href = Linker.offline_link(from_url, to_url)
    assert body =~ href

    opened = Path.expand(link_path(href), Path.dirname(saved(root, from_url)))
    assert File.read!(opened) == File.read!(saved(root, to_url))
  end

  def assert_points(body, from_url, target_url, root, fragment \\ "") do
    href = Linker.offline_link(from_url, target_url <> fragment)
    assert body =~ href

    found = URI.parse(href).fragment
    assert if(found, do: "#" <> found, else: "") == fragment

    assert Path.expand(link_path(href), Path.dirname(saved(root, from_url))) ==
             Path.expand(saved(root, target_url))
  end
end
