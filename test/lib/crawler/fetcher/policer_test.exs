defmodule Crawler.Fetcher.PolicerTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher.Policer
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.Store

  @moduletag capture_log: true

  doctest Policer

  setup do
    Store.ops_reset()

    :ok
  end

  test "max_pages ok" do
    Store.ops_inc()
    Store.ops_inc()

    assert {:ok, %{max_pages: :infinity}} = Policer.police(%{max_pages: :infinity})
  end

  test "max_pages error" do
    Store.ops_inc()
    Store.ops_inc()

    assert {:warn, "Fetch failed check 'within_max_pages?', with opts: " <> _} =
             Policer.police(%{max_pages: 1})
  end

  test "max_depths ok" do
    assert {:ok, %{depth: 1, max_depths: 2}} = Policer.police(%{depth: 1, max_depths: 2})
  end

  test "max_depths error" do
    assert {:warn, "Fetch failed check 'within_fetch_depth?', with opts: " <> _} =
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
    assert {:warn, "Fetch failed check 'acceptable_uri_scheme?', with opts: " <> _} =
             Policer.police(%{url: "ftp://hello.world"})
  end

  test "fetched error" do
    Crawler.Store.add({"http://policer/exist/", nil})

    assert {:warn, "Fetch failed check 'not_fetched_yet?', with opts: " <> _} =
             Policer.police(%{url: "http://policer/exist/", scope: nil})
  end
end
