defmodule Crawler.Snapper.EncodingTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers, only: [saved_artifact: 2]

  alias Crawler.Charset
  alias Crawler.ManagedSnapshotHelpers, as: Managed
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
      scope = unique_scope("snapshot-#{encoding}-#{System.pid()}")
      root = tmp(scope)
      File.rmdir!(root)
      page = "http://ex.com/#{encoding}/page"
      target = "http://ex.com/#{encoding}/café"
      wire_target = "http://ex.com/#{encoding}/caf%c3%a9"
      owner = self()
      decoded = ~s(<p>café</p><a href="café">café</a>)
      {source, type} = source(decoded, encoding)

      assert Charset.decode(source, %{
               content_type: "text/html",
               headers: [{"content-type", type}]
             }) == decoded

      adapter = fn request ->
        requested = URI.to_string(request.url)
        send(owner, {:requested, requested})

        case requested do
          ^page ->
            {request,
             Req.Response.new(status: 200, headers: [{"content-type", type}], body: source)}

          ^wire_target ->
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
                 store: nil,
                 scraper: Scraper,
                 encoding_test_pid: self(),
                 workers: 1,
                 max_body: 1_048_576,
                 max_analysis_bytes: 16_777_216,
                 max_depths: 2,
                 save_to: root,
                 respect_robots: false,
                 req_options: [adapter: adapter, retry: false]
               )

      on_exit(fn ->
        Crawler.stop(opts)
        File.rm_rf!(root)
      end)

      export = Managed.ready_export(opts)

      stored = Store.find_processed({page, scope})

      assert %Store.Page{url: ^page, processed: true, fetch_tag: "a", target_handle: handle} =
               stored

      assert not is_nil(handle)

      assert Map.take(Map.from_struct(stored), [
               :body,
               :opts,
               :analysis,
               :interpretation,
               :source_revision,
               :credit
             ]) ==
               %{
                 body: nil,
                 opts: nil,
                 analysis: nil,
                 interpretation: nil,
                 source_revision: nil,
                 credit: nil
               }

      assert_receive {:scraped, ^page, ^decoded}
      assert_received {:requested, ^page}
      assert_received {:requested, ^wire_target}
      refute_received {:requested, _}
      assert Store.find_processed({target, scope}).url == target
      assert_receive {:scraped, ^target, "<p>TARGET</p>"}

      from = Managed.resource_for_url(export, page)
      to = Managed.reference_target(export, from, target)
      href = Managed.relative_reference(from, to)
      expected = ~s(<p>café</p><a href="#{href}">café</a>)
      assert Managed.read_resource(export, from) == @utf8_bom <> expected
      assert Managed.read_resource(export, to) == @utf8_bom <> "<p>TARGET</p>"
      Managed.assert_opens(export, from, to, href)
    end
  end

  test "HTML snapshots retain exactly one existing UTF-8 BOM" do
    root = tmp("snapshot-existing-bom")
    page = "http://ex.com/page"
    body = @utf8_bom <> "<p>café</p>"

    assert {:ok, artifact} =
             Snapper.snap(body, %{
               url: page,
               save_to: root,
               content_type: "text/html",
               public_id: "encoding00000000000000001"
             })

    assert File.read!(saved_artifact(root, artifact)) == body
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

      assert {:ok, artifact} =
               Snapper.snap(body, %{
                 url: url,
                 save_to: root,
                 content_type: type,
                 public_id: "encoding00000000000000002"
               })

      assert File.read!(saved_artifact(root, artifact)) == body
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
