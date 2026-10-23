defmodule Crawler.Snapper.FragmentSafetyTest do
  use Crawler.OfflineLinkCase, async: false

  import Crawler.TestHelpers, only: [tmp: 1]
  import Crawler.SnapshotHelpers, only: [saved_artifact: 2]

  alias Crawler.ManagedSnapshotHelpers, as: Managed
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.JsParser
  alias Crawler.Snapper

  @fragment ~S|" onclick="alert(1)'`\)&${value}<é>%2f|

  test "rewritten anchor fragments discard URL breaks and trailing C0 input" do
    target = "http://example.com/blog/next"

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
    assert href == "http://example.com/blog/next#%22%20onclick=%22alert%281%29"
    assert href |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode() == fragment
    refute body =~ ~s|onclick="alert(1)"|
  end

  test "HTML, CSS and JavaScript fragments retain URL data through source delimiters" do
    target = "./next#" <> @fragment

    href =
      "http://example.com/blog/next#%22%20onclick=%22alert%281%29%27%60%5c%29%26%24%7bvalue%7d%3c%c3%a9%3e%2f"

    assert href |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode() == URI.decode(@fragment)
    assert href =~ "%2f"

    for quote <- ["\"", "'"] do
      html_value = target |> Floki.Entities.encode() |> IO.iodata_to_binary()
      source = "<a href=#{quote}#{html_value}#{quote}>go</a>"

      encoded =
        "http://example.com/blog/next#%22%20onclick&#61;%22alert%281%29%27%60%5c%29%26%24%7bvalue%7d%3c%c3%a9%3e%2f"

      assert rewrite(source, @page) == "<a href=#{quote}#{encoded}#{quote}>go</a>"
      [actual] = rewrite(source, @page) |> Floki.parse_document!() |> Floki.attribute("a", "href")
      assert actual == href
    end

    for quote <- ["\"", "'"] do
      value = escape(target, quote)
      source = ".x { background:url(#{quote}#{value}#{quote}) }"
      body = rewrite(source, @page, "text/css")
      assert body == ".x { background:url(#{quote}#{href}#{quote}) }"
      assert CssParser.parse(body) == [{"link", [{"href", href}], []}]
      assert href |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode() == URI.decode(@fragment)
    end

    for quote <- ["\"", "'", "`"] do
      value = escape(target, quote)
      source = "import(#{quote}#{value}#{quote});"
      body = rewrite(source, @page, "application/javascript")
      assert body == "import(#{quote}#{href}#{quote});"
      assert JsParser.specs(body) == [href]
      assert href |> URI.parse() |> Map.fetch!(:fragment) |> URI.decode() == URI.decode(@fragment)
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

    export = managed_export(root, page, source, [{target, target_body, "text/html"}], assets: [])
    from = Managed.resource_for_url(export, page)
    to = Managed.reference_target(export, from, target)

    [href] =
      export
      |> Managed.read_resource(from)
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    encoded_fragment = "#%22%27%29%5c%26%24%7banchor%7d%3c%c3%a9%3e"
    Managed.assert_opens(export, from, to, href, encoded_fragment)
    assert Managed.read_resource(export, to) == <<0xEF, 0xBB, 0xBF>> <> target_body

    [id] =
      export |> Managed.read_resource(to) |> Floki.parse_document!() |> Floki.attribute("p", "id")

    assert URI.decode(URI.parse(href).fragment) == id
    assert id == fragment
  end

  test "standalone public ID acknowledgements preserve escaped anchor and online fragment values" do
    root = tmp("standalone-fragment-ack-source")
    page_url = "http://example.com/index.html"
    target_url = "http://example.com/next"
    fragment = ~S|"')\&${anchor}<é>|
    anchor = fragment |> Floki.Entities.encode() |> IO.iodata_to_binary()
    target_body = ~s|<p id="#{anchor}">TARGET</p>|
    source = ~s|<a href="next##{anchor}">open</a>|
    target_id = "standalone000000000006001"
    page_id = "standalone000000000006002"

    opts = %{
      save_to: root,
      content_type: "text/html",
      html_tag: "a",
      assets: [],
      depth: 1,
      max_depths: 3
    }

    assert {:ok, %{public_id: ^target_id} = target} =
             Snapper.snap(target_body, Map.merge(opts, %{public_id: target_id, url: target_url}))

    assert {:ok, %{public_id: ^page_id} = page} =
             Snapper.snap(source, Map.merge(opts, %{public_id: page_id, url: page_url}))

    expected_href = "http://example.com/next#%22%27%29%5c%26%24%7banchor%7d%3c%c3%a9%3e"
    target_saved = File.read!(saved_artifact(root, target))
    page_saved = File.read!(saved_artifact(root, page))
    assert target_saved == <<0xEF, 0xBB, 0xBF>> <> target_body
    assert page_saved == <<0xEF, 0xBB, 0xBF>> <> ~s|<a href="#{expected_href}">open</a>|
    [{"a", [{"href", href}], ["open"]}] = Floki.find(Floki.parse_document!(page_saved), "a")
    assert href == expected_href
    [id] = target_saved |> Floki.parse_document!() |> Floki.attribute("p", "id")
    assert URI.decode(URI.parse(href).fragment) == id
    assert id == fragment
  end

  defp escape(value, quote) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(quote, "\\" <> quote)
    |> then(fn value -> if quote == "`", do: String.replace(value, "${", "\\${"), else: value end)
  end

  defp managed_export(root, page, source, targets, options) do
    File.rmdir!(root)
    root = root <> "-#{System.pid()}-#{System.unique_integer([:positive])}"
    requests = Crawler.RequestLog.new()

    route_key = fn url ->
      uri = url |> Crawler.URL.canonical() |> URI.parse()
      URI.to_string(%{uri | query: uri.query || ""})
    end

    routes =
      Map.new([{page, source, "text/html"} | targets], fn {url, body, type} ->
        {route_key.(url), {body, type}}
      end)

    plug = fn conn ->
      key = conn |> Plug.Conn.request_url() |> route_key.()
      Crawler.RequestLog.record(requests, key)
      {body, type} = Map.fetch!(routes, key)
      conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.resp(200, body)
    end

    assert {:ok, opts} =
             Crawler.crawl(
               page,
               Keyword.merge(
                 [
                   scope: Crawler.TestHelpers.unique_scope("managed-snapshot"),
                   save_to: root,
                   store: nil,
                   workers: 1,
                   max_body: 1_048_576,
                   max_analysis_bytes: 16_777_216,
                   max_depths: 3,
                   respect_robots: false,
                   req_options: [plug: plug, retry: false]
                 ],
                 options
               )
             )

    on_exit(fn ->
      Crawler.stop(opts)
      File.rm_rf!(root)
    end)

    export = Managed.ready_export(opts)

    assert Crawler.RequestLog.frequencies(requests) ==
             Map.new(routes, fn {url, _} -> {url, 1} end)

    export
  end
end
