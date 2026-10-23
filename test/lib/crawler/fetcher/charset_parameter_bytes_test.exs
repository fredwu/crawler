defmodule Crawler.Fetcher.CharsetParameterBytesTest do
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

  test "HTTP parameters select valid encoding bytes through fetching and saving", context do
    field = "text/html; charset=" <> <<255>> <> "; charset=latin1"
    source = "caf" <> <<0xE9>>
    assert_snapshot(context, "/http-parameter.html", field, source, "café")
  end

  test "meta content parameters select valid encoding bytes through fetching and saving",
       context do
    source =
      ~s|<meta http-equiv="content-type" content="text/html; charset=| <>
        <<255>> <> ~s|; charset=latin1">caf| <> <<0xE9>>

    decoded =
      ~s|<meta http-equiv="content-type" content="text/html; charset=utf-8; charset=latin1">café|

    assert_snapshot(context, "/meta-parameter.html", "text/html", source, decoded)
  end

  defp assert_snapshot(context, path, type, source, decoded) do
    url = context.url <> path

    root =
      Path.join(
        tmp("charset-parameter-bytes-#{context.path}"),
        "export-#{System.os_time(:nanosecond)}"
      )

    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", type)
      |> Plug.Conn.resp(200, source)
    end)

    scope = unique_scope("charset-export")

    on_exit(fn ->
      Crawler.stop(%{scope: scope})
      File.rm_rf(root)
    end)

    assert %Page{body: ^decoded, opts: %{content_type: "text/html"}} =
             page =
             Fetcher.fetch(%{
               url: url,
               scope: scope,
               req_options: context.req_options,
               modifier: Modifier,
               retrier: Once,
               user_agent: "Crawler Test",
               depth: 0,
               store: nil,
               max_body: 1_048_576,
               max_analysis_bytes: 8_000_000,
               save_to: root,
               html_tag: "a",
               max_depths: 1
             })

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
    resource = resource_for_url(export, url)
    assert resource["content_type"] == "text/html"
    assert read_resource(export, resource) == <<0xEF, 0xBB, 0xBF>> <> decoded
    assert :ok = Store.release_page(page)
  end
end
