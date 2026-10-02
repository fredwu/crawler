defmodule Crawler.Linker.PathOfflinerTest do
  use Crawler.TestCase, async: true

  alias Crawler.Linker.PathOffliner

  doctest PathOffliner

  test "known MIME extensions retain their file names" do
    extensions = MIME.known_types() |> Map.values() |> List.flatten() |> Enum.uniq()

    for extension <- extensions do
      filename = "ex.com/report.#{extension}"
      assert PathOffliner.transform(filename) == filename
    end
  end

  test "crawler-specific extensions stay files" do
    for extension <- ~w(cjs ogg m4a map vtt appcache asp aspx) do
      filename = "ex.com/asset.#{extension}"
      assert PathOffliner.transform(filename) == filename
    end
  end

  test "unrecognized dotted directories retain their index and child paths" do
    assert PathOffliner.transform("ex.com/about.me") == "ex.com/about.me/__index.html"
    assert PathOffliner.transform("ex.com/about.me/team") == "ex.com/about.me/team/__index.html"
  end

  test "repeated trailing separators retain distinct empty path segments" do
    assert PathOffliner.transform("ex.com/a//") == "ex.com/a//__index.html"
    assert PathOffliner.transform("ex.com/a///") == "ex.com/a///__index.html"
    assert PathOffliner.transform("ex.com/app.js/") == "ex.com/app.js"
    assert PathOffliner.transform("ex.com/app.js//") == "ex.com/app.js//__index.html"
  end
end
