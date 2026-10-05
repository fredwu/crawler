defmodule Crawler.Fetcher.CharsetMediaTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher
  alias Crawler.Fetcher.Modifier
  alias Crawler.Fetcher.Retrier
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
             fetch(context, "/form-feed", "text/html", source)
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

  defp fetch(context, path, type, source) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", type)
      |> Plug.Conn.resp(200, source)
    end)

    Fetcher.fetch(%{
      url: context.url <> path,
      req_options: context.req_options,
      modifier: Modifier,
      retrier: Once,
      user_agent: "Crawler Test",
      depth: 0,
      store: nil
    })
  end
end
