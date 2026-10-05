defmodule Crawler.Snapper.FragmentSafetyTest do
  use Crawler.OfflineLinkCase, async: true

  import Crawler.TestHelpers, only: [tmp: 1]
  import Crawler.SnapshotHelpers, only: [link_path: 1, saved: 2]

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.JsParser
  alias Crawler.Snapper

  @fragment ~S|" onclick="alert(1)'`\)&${value}<é>%2f|

  test "rewritten anchor fragments discard URL breaks and trailing C0 input" do
    target = Linker.offline_link(@page, "next")

    for {fragment, expected} <- [
          {"x\ny", "xy"},
          {"x\ry", "xy"},
          {"x\ty", "xy"},
          {"xy\x01\x1F ", "xy"},
          {"x%0Ay%0D%09%00%2F", "x%0Ay%0D%09%00%2F"},
          {"x%ZZ", "x%25ZZ"}
        ] do
      source = ~s|<a href="next##{fragment}" title="keep">go</a>|

      assert rewrite(source, @page) ==
               ~s|<a href="#{target}##{expected}" title="keep">go</a>|
    end
  end

  test "entity-decoded anchor fragments stay inside their original attribute" do
    source = ~s|<a href="next#&quot; onclick=&quot;alert(1)" title="keep">go</a>|
    fragment = ~s|" onclick="alert(1)|
    body = rewrite(source, @page)
    [{"a", attrs, ["go"]}] = Floki.parse_fragment!(body)
    assert Enum.map(attrs, &elem(&1, 0)) == ["href", "title"]
    assert {"title", "keep"} in attrs
    {"href", href} = List.keyfind(attrs, "href", 0)
    assert href == Linker.offline_link(@page, "next#" <> fragment)
    assert href |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode() == fragment
    refute body =~ ~s|onclick="alert(1)"|
  end

  test "HTML, CSS and JavaScript fragments retain URL data through source delimiters" do
    target = "./next#" <> @fragment
    href = Linker.offline_link(@page, target)
    assert href |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode() == URI.decode(@fragment)
    assert href =~ "%2f"

    for quote <- ["\"", "'"] do
      html_value = target |> Floki.Entities.encode() |> IO.iodata_to_binary()
      source = "<a href=#{quote}#{html_value}#{quote}>go</a>"
      assert rewrite(source, @page) == "<a href=#{quote}#{href}#{quote}>go</a>"
    end

    for quote <- ["\"", "'"] do
      value = escape(target, quote)
      source = ".x { background:url(#{quote}#{value}#{quote}) }"
      body = rewrite(source, @page, "text/css")
      assert body == ".x { background:url(#{quote}#{href}#{quote}) }"
      assert CssParser.parse(body) == [{"link", [{"href", href}], []}]
    end

    for quote <- ["\"", "'", "`"] do
      value = escape(target, quote)
      source = "import(#{quote}#{value}#{quote});"
      body = rewrite(source, @page, "application/javascript")
      assert body == "import(#{quote}#{href}#{quote});"
      assert JsParser.specs(body) == [href]
    end
  end

  test "encoded saved fragments open the target document and preserve the anchor value" do
    root = tmp("snapshot-fragment-source-safety")
    page = "http://example.com/index.html"
    target = "http://example.com/next"
    fragment = ~S|"')\&${anchor}<é>|
    anchor = fragment |> Floki.Entities.encode() |> IO.iodata_to_binary()
    target_body = ~s|<p id="#{anchor}">TARGET</p>|
    source = ~s|<a href="next##{anchor}">open</a>|

    for {url, body} <- [{target, target_body}, {page, source}] do
      assert {:ok, _opts} =
               Snapper.snap(body, %{
                 url: url,
                 save_to: root,
                 content_type: "text/html",
                 html_tag: "a",
                 assets: [],
                 depth: 1,
                 max_depths: 3
               })
    end

    [href] =
      root
      |> saved(page)
      |> File.read!()
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    opened = Path.expand(link_path(href), Path.dirname(saved(root, page)))
    assert opened == Path.expand(saved(root, target))
    [id] = opened |> File.read!() |> Floki.parse_document!() |> Floki.attribute("p", "id")
    assert URI.decode(URI.parse(href).fragment) == id
    assert id == fragment
  end

  defp escape(value, quote) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(quote, "\\" <> quote)
    |> then(fn value -> if quote == "`", do: String.replace(value, "${", "\\${"), else: value end)
  end
end
