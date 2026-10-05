defmodule Crawler.Fetcher.PolicerTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher.Policer
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.Store

  doctest Policer

  setup do
    scope = unique_scope("policer")
    on_exit(fn -> Store.drop_scope(scope) end)
    {:ok, scope: scope}
  end

  test "max_pages ok", %{scope: scope} do
    Store.ops_inc(scope)
    Store.ops_inc(scope)

    assert {:ok, %{max_pages: :infinity, scope: ^scope}} =
             Policer.police(%{max_pages: :infinity, scope: scope})
  end

  test "max_pages error", %{scope: scope} do
    Store.ops_inc(scope)
    Store.ops_inc(scope)

    assert {:warn, "Fetch failed check 'within_max_pages?', crawl: " <> _} =
             Policer.police(%{max_pages: 1, scope: scope})
  end

  test "max_depths ok" do
    assert {:ok, %{depth: 1, max_depths: 2}} = Policer.police(%{depth: 1, max_depths: 2})
  end

  test "max_depths error" do
    assert {:warn, "Fetch failed check 'within_fetch_depth?', crawl: " <> _} =
             Policer.police(%{
               depth: 2,
               max_depths: 2,
               html_tag: "a"
             })
  end

  test "uri_scheme ok" do
    assert {:ok,
            %{
              html_tag: "img",
              url: "http://policer/hi.jpg",
              url_filter: UrlFilter
            }} =
             Policer.police(%{
               html_tag: "img",
               url: "http://policer/hi.jpg",
               url_filter: UrlFilter
             })
  end

  test "uri_scheme error" do
    assert {:warn, "Fetch failed check 'acceptable_uri_scheme?', crawl: " <> _} =
             Policer.police(%{url: "ftp://hello.world"})
  end

  test "fetched error", %{scope: scope} do
    Store.add({"http://policer/exist/", scope})

    assert {:warn, "Fetch failed check 'not_fetched_yet?', crawl: " <> _} =
             Policer.police(%{url: "http://policer/exist/", scope: scope})
  end
end
