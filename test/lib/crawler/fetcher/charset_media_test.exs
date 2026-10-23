defmodule Crawler.Fetcher.CharsetMediaTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Fetcher
  alias Crawler.Fetcher.Modifier
  alias Crawler.Fetcher.Retrier
  alias Crawler.Store
  alias Crawler.Store.Page

  defmodule Once do
    @behaviour Retrier.Spec

    def perform(fetch, _opts), do: fetch.()
  end

  test "the fetch path skips supported fake charsets in quoted response parameters", context do
    for {header, index} <-
          Enum.with_index([
            ~S|text/html; note="a; charset=latin1; b"; charset=utf-8|,
            ~S|text/html; note="a\"; charset=latin1; b"; charset=utf-8|
          ]) do
      assert %Page{body: "café", opts: %{content_type: "text/html"}} =
               fetch(context, "/quoted-#{index}", header, "café")
    end
  end

  test "the fetch path reads form feed around a direct meta label", context do
    source = "<meta charset=\"\flatin1\f\">caf" <> <<0xE9>>

    assert %Page{body: ~s|<meta charset="utf-8">café|} =
             fetch(context, "/form-feed", "text/html", source, ~s|<meta charset="utf-8">café|)
  end

  test "the fetch path preserves opaque MIME bodies byte for byte", context do
    source = <<255, 0, 65>>

    for {type, index} <- Enum.with_index(["application/xhtml-binary", "textual/octet-stream"]) do
      assert %Page{body: ^source, opts: %{content_type: ^type}} =
               fetch(context, "/opaque-#{index}", type <> "; charset=latin1", source)
    end
  end

  test "the fetch path treats an HTML-like text subtype as ordinary text", context do
    source = ~s|<meta charset="latin1">café|

    assert %Page{body: ^source, opts: %{content_type: "text/html-template"}} =
             fetch(context, "/text-template", "text/html-template", source)
  end

  defp fetch(context, path, type, source, decoded \\ nil) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", type)
      |> Plug.Conn.resp(200, source)
    end)

    root =
      Path.join(
        tmp("charset-media-#{context.path}"),
        Path.basename(path) <> "-#{System.os_time(:nanosecond)}"
      )

    scope = unique_scope("charset-media")

    on_exit(fn ->
      Crawler.stop(%{scope: scope})
      File.rm_rf(root)
    end)

    page =
      Fetcher.fetch(%{
        url: context.url <> path,
        scope: scope,
        req_options: context.req_options,
        modifier: Modifier,
        retrier: Once,
        user_agent: "Crawler Test",
        depth: 0,
        store: nil,
        max_body: 1_048_576,
        max_analysis_bytes: 8_000_000,
        save_to: root
      })

    assert %Page{} = page
    assert is_reference(page.source_revision)
    assert page.interpretation.source == page.body
    assert page.interpretation.source_revision == page.source_revision

    assert %Page{
             body: nil,
             opts: nil,
             analysis: nil,
             interpretation: nil,
             source_revision: nil,
             credit: nil
           } = stored = Store.find({page.url, scope})

    assert stored.url == page.url
    assert stored.fetch_tag == page.opts[:html_tag]
    assert stored.target_handle == page.target_handle
    on_exit(fn -> Store.release_page(page) end)

    export = ready_export(page.opts)
    resource = resource_for_url(export, context.url <> path)
    assert resource["content_type"] == page.opts.content_type
    decoded = decoded || source
    assert page.body == decoded

    expected =
      if page.opts.content_type == "text/html",
        do: <<0xEF, 0xBB, 0xBF>> <> decoded,
        else: source

    assert read_resource(export, resource) == expected
    assert :ok = Store.release_page(page)
    page
  end
end
