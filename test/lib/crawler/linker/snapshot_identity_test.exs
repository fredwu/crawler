defmodule Crawler.Linker.SnapshotIdentityTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker.Snapshot
  alias Crawler.URL

  test "canonically equivalent precomposed characters retain separate files" do
    root =
      Path.join(
        System.tmp_dir!(),
        "crawler-snapshot-identity-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    pairs = [
      {0x03AC, 0x1F71, "001f71"},
      {0x8C48, 0xF900, "00f900"}
    ]

    for {stable, changing, hex} <- pairs do
      stable_url = "http://ex.com/" <> <<stable::utf8>>
      changing_url = "http://ex.com/" <> <<changing::utf8>>
      literal_url = "http://ex.com/__u_#{hex}"

      refute URL.normalize(stable_url) == URL.normalize(changing_url)
      assert String.normalize(stable_url, :nfc) == String.normalize(changing_url, :nfc)

      stable_path = Snapshot.path(stable_url)
      changing_path = Snapshot.path(changing_url)
      literal_path = Snapshot.path(literal_url)

      assert stable_path == "ex.com/" <> <<stable::utf8>> <> "/__index.html"
      assert changing_path == "ex.com/__u_#{hex}/__index.html"
      assert literal_path == "ex.com/__u%5f#{hex}/__index.html"

      paths = [stable_path, changing_path, literal_path]
      folded = Enum.map(paths, &(&1 |> String.normalize(:nfd) |> :string.casefold()))
      assert length(Enum.uniq(folded)) == length(paths)

      files = Enum.zip(paths, ["STABLE", "CHANGING", "LITERAL"])

      for {path, body} <- files do
        file = Path.join(root, path)
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, body)
      end

      for {path, body} <- files do
        assert File.read!(Path.join(root, path)) == body
      end
    end
  end
end
