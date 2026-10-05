defmodule Crawler.Fetcher.CharsetParameterBytesTest do
  use Crawler.TestCase, async: true

  import Crawler.SnapshotHelpers

  alias Crawler.Fetcher
  alias Crawler.Fetcher.Modifier
  alias Crawler.Fetcher.Retrier
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
    root = tmp("charset-parameter-bytes-#{context.path}")

    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", type)
      |> Plug.Conn.resp(200, source)
    end)

    assert %Page{body: ^decoded} =
             Fetcher.fetch(%{
               url: url,
               req_options: context.req_options,
               modifier: Modifier,
               retrier: Once,
               user_agent: "Crawler Test",
               depth: 0,
               store: nil,
               save_to: root,
               html_tag: "a",
               max_depths: 1
             })

    assert File.read!(saved(root, url)) == <<0xEF, 0xBB, 0xBF>> <> decoded
  end
end
