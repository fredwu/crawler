defmodule Crawler.Fetcher.LiteralCharsetQuoteTest do
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

  test "literal inner quotes do not corrupt fetched or saved UTF-8 text", context do
    root = tmp("literal-charset-quotes-#{context.path}")
    on_exit(fn -> File.rm_rf(root) end)

    for {label, index} <- Enum.with_index(["'latin1", "latin1'", "'latin1'"]) do
      source = ~s|<meta charset="#{label}"><meta charset="utf-8">café|
      decoded = ~s|<meta charset="utf-8"><meta charset="utf-8">café|
      path = "/literal-label-#{index}.html"
      url = context.url <> path

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
end
