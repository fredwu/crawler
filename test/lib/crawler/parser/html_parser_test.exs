defmodule Crawler.Parser.HtmlParserTest do
  use Crawler.TestCase, async: true

  alias Crawler.Parser.HtmlParser

  doctest HtmlParser

  test "finds script tags that omit type='text/javascript'" do
    html = """
    <script src="/app.js"></script>
    <script type="module" src="/mod.js"></script>
    <script type="text/javascript">inline</script>
    """

    assert [
             {"script", [{"src", "/app.js"}], _app},
             {"script", [{"type", "module"}, {"src", "/mod.js"}], _mod}
           ] = HtmlParser.parse(html, %{assets: ["js"]})
  end

  test "finds media tags and stylesheet links" do
    html = """
    <img src="a.jpg" srcset="b.jpg 2x">
    <picture><source srcset="c.webp"></picture>
    <video src="d.mp4" poster="d.jpg"></video>
    <audio src="e.mp3"></audio>
    <link rel="preload" as="style" href="pre.css">
    <link rel="stylesheet alternate" href="alt.css">
    <style>body{background:url(bg.png)}</style>
    <div style="background: url('bg2.png')"></div>
    """

    tags =
      html
      |> HtmlParser.parse(%{assets: ["images", "css"]})
      |> Enum.map(&elem(&1, 0))

    assert "img" in tags
    assert "source" in tags
    assert "video" in tags
    assert "audio" in tags
    assert "link" in tags
    assert "style" in tags
    assert "div" in tags
  end
end
