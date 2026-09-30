defmodule Crawler.Linker.SnapshotTest do
  use ExUnit.Case, async: true

  import Crawler.TestHelpers

  alias Crawler.Linker
  alias Crawler.Linker.Snapshot
  alias Crawler.Snapper

  test "parent links expand to the file that was saved" do
    page = "http://example.com/blog/post"
    about = "http://example.com/about"
    css = "http://example.com/css/app.css"
    image = "http://example.com/images/a.png"
    dotted = "http://example.com/a/../../about"

    assert_expands(page, "../../about", about)
    assert_expands(page, dotted, about)
    assert_expands(css, "../../images/a.png", image)
    assert_expands("http://example.com/app.css", "../images/a.png", image)
  end

  test "equivalent urls share one snapshot path" do
    assert Snapshot.path("http://Example.com/a/../b") == Snapshot.path("http://example.com/b")
    assert Snapshot.path("http://example.com/a/./c") == Snapshot.path("http://example.com/a/c")
    assert Snapshot.path("http://example.com/a#section") == Snapshot.path("http://example.com/a")

    refute Snapshot.path("http://example.com/a/.../c") == Snapshot.path("http://example.com/a/c")
  end

  test "a colon does not share a file with a dash" do
    port = Snapshot.path("http://ex.com:8080/a")
    dashed_host = Snapshot.path("http://ex.com-8080/a")
    colon = Snapshot.path("http://ex.com/foo:bar")
    dashed_path = Snapshot.path("http://ex.com/foo-bar")

    assert port != dashed_host
    assert colon != dashed_path
    refute port =~ ":"
    refute colon =~ ":"
    assert port =~ "ex.com__port_8080/a/__index.html"

    assert Snapshot.path("http://ex.com:8080/foo:bar") ==
             "ex.com__port_8080/foo__c_bar/__index.html"

    assert colon =~ "foo__c_bar"
    assert Snapshot.path("http://ex.com:80/a") == Snapshot.path("http://ex.com/a")
    assert Snapshot.path("https://ex.com:443/a") == Snapshot.path("https://ex.com/a")
    refute Snapshot.path("http://ex.com:80/a") =~ "__port_"
    assert Snapshot.path("http://ex.com/foo__c_bar") =~ "foo__c%5Fbar"
    assert Snapshot.path("http://ex.com__port_8080/a") =~ "ex.com__port%5F8080"
    refute Snapshot.path("http://ex.com/a?x=1:2") =~ ":"
  end

  test "saved links expand to distinct colon and dash files" do
    root = tmp("snapshot-colon")
    page = "http://ex.com/page"
    port = "http://ex.com:8080/a"
    dashed_host = "http://ex.com-8080/a"
    colon = "http://ex.com/foo:bar"
    dashed_path = "http://ex.com/foo-bar"

    html =
      ~s(<a href="#{port}"></a><a href="#{dashed_host}"></a><a href="#{colon}"></a><a href="#{dashed_path}"></a>)

    snap(html, page, root)
    snap("PORT", port, root)
    snap("DASH", dashed_host, root)
    snap("COLON", colon, root)
    snap("HYPHEN", dashed_path, root)

    assert File.read!(file(root, port)) == "PORT"
    assert File.read!(file(root, dashed_host)) == "DASH"
    assert File.read!(file(root, colon)) == "COLON"
    assert File.read!(file(root, dashed_path)) == "HYPHEN"

    saved = File.read!(file(root, page))
    assert_saved_expands(saved, page, port, root)
    assert_saved_expands(saved, page, dashed_host, root)
    assert_saved_expands(saved, page, colon, root)
    assert_saved_expands(saved, page, dashed_path, root)
  end

  test "empty path segments do not share a file" do
    root = tmp("snapshot-empty")
    page = "http://example.com/page"
    doubled = "http://example.com/a//b"
    plain = "http://example.com/a/b"
    leading = "http://example.com//a"
    normal = "http://example.com/a"
    marker = "http://example.com/a/__e_/b"

    assert Snapshot.path(doubled) != Snapshot.path(plain)
    assert Snapshot.path(leading) != Snapshot.path(normal)
    assert Snapshot.path(doubled) != Snapshot.path(marker)
    refute Snapshot.path(doubled) =~ "//"
    assert Snapshot.path(doubled) =~ "__e_"

    snap("PAGE", page, root)
    snap("DOUBLED", doubled, root)
    snap("PLAIN", plain, root)
    snap("LEAD", leading, root)
    snap("NORM", normal, root)
    snap("MARK", marker, root)
    snap(~s(<a href="#{doubled}"></a>), page, root)

    assert File.read!(file(root, doubled)) == "DOUBLED"
    assert File.read!(file(root, plain)) == "PLAIN"
    assert File.read!(file(root, leading)) == "LEAD"
    assert File.read!(file(root, normal)) == "NORM"
    assert File.read!(file(root, marker)) == "MARK"
    assert_saved_expands(File.read!(file(root, page)), page, doubled, root)
  end

  test "keeps the fragment on the offline link" do
    href = Linker.offline_link("http://example.com/blog/post", "post.html?q=1#section")

    assert String.ends_with?(href, "#section")
    assert href =~ "__q_"
    refute href =~ "post.html?q=1#section"
  end

  defp assert_expands(from_url, link, target_url) do
    href = Linker.offline_link(from_url, link)
    {path, _fragment} = split_fragment(href)

    assert Path.expand(path, Path.dirname(Snapshot.path(from_url))) ==
             Path.expand(Snapshot.path(target_url))
  end

  defp assert_saved_expands(body, from_url, target_url, root) do
    href = Linker.offline_link(from_url, target_url)
    assert body =~ href
    {path, _fragment} = split_fragment(href)
    saved = file(root, from_url)

    assert Path.expand(path, Path.dirname(saved)) == Path.expand(file(root, target_url))
  end

  defp file(root, url), do: Path.join(root, Snapshot.path(url))

  defp split_fragment(href) do
    case String.split(href, "#", parts: 2) do
      [path, fragment] -> {path, "#" <> fragment}
      [path] -> {path, ""}
    end
  end

  defp snap(body, url, root) do
    assert {:ok, _opts} =
             Snapper.snap(body, %{
               url: url,
               referrer_url: url,
               save_to: root,
               html_tag: "a",
               content_type: "text/html",
               depth: 1,
               max_depths: 2
             })
  end
end
