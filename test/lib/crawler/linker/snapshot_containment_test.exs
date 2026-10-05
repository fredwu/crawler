defmodule Crawler.Linker.SnapshotContainmentTest do
  use ExUnit.Case, async: true

  import Crawler.SnapshotHelpers, only: [link_path: 1]
  import Crawler.TestHelpers, only: [tmp: 1]

  alias Crawler.Linker
  alias Crawler.Linker.Snapshot
  alias Crawler.Snapper
  alias Crawler.URL

  test "encoded dot hosts share identities while saved files stay within the archive" do
    root = tmp("snapshot-dot-hosts/archive")
    page = "http://example.com/index.html"

    groups = [
      ["http://./a", "http://%2e/a"],
      ["http://../a", "http://%2e%2e/a"]
    ]

    paths = Enum.map(groups, fn [url | _] -> Snapshot.path(url) end)

    assert length(Enum.uniq(paths)) == length(groups)

    for [canonical | _] = spellings <- groups, url <- spellings do
      path = Snapshot.path(url)
      assert URL.normalize(url) == canonical
      assert URL.canonical(url) == URL.canonical(canonical)
      assert path == Snapshot.path(canonical)
      saved = Path.expand(path, root)
      assert String.starts_with?(saved, Path.expand(root) <> "/")
      refute Enum.any?(String.split(path, "/"), &(&1 in [".", ".."]))

      assert {:ok, _opts} =
               Snapper.snap(canonical, %{
                 url: url,
                 referrer_url: url,
                 save_to: root,
                 html_tag: "a",
                 content_type: "text/plain"
               })

      assert File.read!(saved) == canonical

      href = Linker.offline_link(page, url)
      opened = Path.expand(link_path(href), Path.dirname(Path.join(root, Snapshot.path(page))))
      assert opened == saved
    end
  end
end
