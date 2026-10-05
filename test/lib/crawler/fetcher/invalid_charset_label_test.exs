defmodule Crawler.Fetcher.InvalidCharsetLabelTest do
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

  test "fetching and saving skips a malformed meta label before a supported one", context do
    source =
      ~s|<meta charset="| <> <<255>> <> ~s|"><meta charset="latin1">caf| <> <<0xE9>>

    decoded = ~s|<meta charset="utf-8"><meta charset="utf-8">café|
    path = "/invalid-label.html"
    url = context.url <> path
    root = tmp("invalid-charset-label-#{context.path}")

    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
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
