defmodule Crawler.Snapper.EncodingTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Charset
  alias Crawler.Linker
  alias Crawler.Snapper
  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  defmodule Scraper do
    @behaviour Crawler.Scraper.Spec

    def scrape(page) do
      send(page.opts[:encoding_test_pid], {:scraped, page.url, page.body})
      {:ok, page}
    end
  end

  for encoding <- [:utf8_bom, :utf16_le_bom, :utf16_be_bom, :latin1_header] do
    test "saved HTML declares UTF-8 after decoding #{encoding}" do
      encoding = unquote(encoding)
      scope = unique_scope("snapshot-#{encoding}")
      root = tmp(scope)
      page = "http://ex.com/#{encoding}/page"
      target = "http://ex.com/#{encoding}/café"
      decoded = ~s(<p>café</p><a href="café">café</a>)
      {source, type} = source(decoded, encoding)

      assert Charset.decode(source, %{
               content_type: "text/html",
               headers: [{"content-type", type}]
             }) == decoded

      adapter = fn request ->
        case URI.to_string(request.url) do
          ^page ->
            {request,
             Req.Response.new(status: 200, headers: [{"content-type", type}], body: source)}

          ^target ->
            {request,
             Req.Response.new(
               status: 200,
               headers: [{"content-type", "text/html"}],
               body: "<p>TARGET</p>"
             )}
        end
      end

      assert {:ok, opts} =
               Crawler.crawl(page,
                 scope: scope,
                 store: Store,
                 scraper: Scraper,
                 encoding_test_pid: self(),
                 workers: 1,
                 max_depths: 2,
                 save_to: root,
                 req_options: [adapter: adapter, retry: false]
               )

      on_exit(fn -> Crawler.stop(opts) end)
      await_idle(opts)

      assert Store.find_processed({page, scope}).body == decoded
      assert_receive {:scraped, ^page, ^decoded}

      expected = ~s(<p>café</p><a href="#{Linker.offline_link(page, target)}">café</a>)
      assert File.read!(saved(root, page)) == @utf8_bom <> expected
      assert File.read!(saved(root, target)) == @utf8_bom <> "<p>TARGET</p>"
      assert_link_opens(root, page, target)
    end
  end

  test "HTML snapshots retain exactly one existing UTF-8 BOM" do
    root = tmp("snapshot-existing-bom")
    page = "http://ex.com/page"
    body = @utf8_bom <> "<p>café</p>"

    assert {:ok, _opts} =
             Snapper.snap(body, %{url: page, save_to: root, content_type: "text/html"})

    assert File.read!(saved(root, page)) == body
  end

  test "non-HTML snapshot bytes stay unchanged" do
    root = tmp("snapshot-non-html")

    for {name, type, body} <- [
          {"page.xhtml", "application/xhtml+xml",
           ~s(<?xml version="1.0" encoding="utf-8"?><html>café</html>)},
          {"page.xml", "application/xml",
           ~s(<?xml version="1.0" encoding="utf-8"?><root>café</root>)},
          {"style.css", "text/css", ~s(@charset "utf-8"; .café { color: red })},
          {"app.js", "text/javascript", ~s(const label = "café";)},
          {"notes.txt", "text/plain", "café"},
          {"image.png", "image/png", <<0x89, 0xE9>>}
        ] do
      url = "http://ex.com/#{name}"
      assert {:ok, _opts} = Snapper.snap(body, %{url: url, save_to: root, content_type: type})
      assert File.read!(saved(root, url)) == body
    end
  end

  defp source(body, :utf8_bom), do: {@utf8_bom <> body, "text/html"}

  defp source(body, :utf16_le_bom) do
    {<<0xFF, 0xFE>> <> :unicode.characters_to_binary(body, :utf8, {:utf16, :little}), "text/html"}
  end

  defp source(body, :utf16_be_bom) do
    {<<0xFE, 0xFF>> <> :unicode.characters_to_binary(body, :utf8, {:utf16, :big}), "text/html"}
  end

  defp source(body, :latin1_header) do
    {:unicode.characters_to_binary(body, :utf8, :latin1), "text/html; charset=iso-8859-1"}
  end
end
