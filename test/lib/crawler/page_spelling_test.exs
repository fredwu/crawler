defmodule Crawler.PageSpellingTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Linker
  alias Crawler.Linker.Snapshot
  alias Crawler.RequestLog
  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "equivalent spellings are fetched once and the saved link opens that file", %{site: _site} do
    hub = "http://ex.com/spell/hub"
    space = "http://ex.com/spell/my%20page"
    slash = "http://ex.com/spell/a%2fb"

    groups = %{
      space => %{
        wire: space,
        spellings: [
          "http://ex.com/spell/a/%2e%2e/my%20page#part",
          "http://EX.com./spell/my page",
          "http://ex.com/spell/my%20page",
          "http://ex.com/spell/sub\\..\\my page",
          "http:\\\\ex.com\\spell\\my page",
          "ht\ttp://ex.com/spell/my%20page",
          "http://ex.com/spell/my%20page#other"
        ]
      },
      slash => %{
        wire: slash,
        spellings: [
          "http://ex.com/spell/a%2Fb",
          "http://ex.com/spell/a%2fb#z"
        ]
      }
    }

    scope = "spell-same"
    root = tmp("spell-same")
    seen = RequestLog.new()

    crawl(hub, scope, root, spell_adapter(seen, hub, groups))

    assert RequestLog.frequencies(seen) == %{hub => 1, space => 1, slash => 1}
    assert Store.ops_count(scope) == 3

    Enum.each(groups, fn {page, %{spellings: spellings}} ->
      assert Enum.uniq(Enum.map(spellings, &Snapshot.path/1)) == [Snapshot.path(page)]

      Enum.each(spellings, fn spelling ->
        assert Store.find({spelling, scope}).body == "PAGE #{page}"
        assert_link_opens(root, hub, spelling)
      end)
    end)

    assert Linker.offline_link(hub, "http://ex.com/spell/a/%2e%2e/my%20page#part") =~ "#part"
    assert Linker.offline_link(hub, "http://ex.com/spell/a%2fb#z") =~ "#z"
  end

  test "a unicode host and its punycode spelling share one file", %{site: _site} do
    hub = "http://ex.com/idn/hub"
    page = "http://xn--xample-9ua.com/p"
    spellings = ["http://éxample.com/p", "http://ÉXAMPLE.COM./p#top"]
    scope = "spell-idn"
    root = tmp("spell-idn")
    seen = RequestLog.new()

    crawl(hub, scope, root, single_target(seen, hub, page, spellings),
      url_filter: Crawler.AllowFilter
    )

    assert RequestLog.frequencies(seen) == %{hub => 1, page => 1}
    assert Store.find({page, scope}).body == "PAGE #{page}"

    Enum.each(spellings, fn spelling ->
      assert Store.find({spelling, scope}).body == "PAGE #{page}"
      assert Snapshot.path(spelling) == Snapshot.path(page)
      assert_link_opens(root, hub, spelling)
    end)

    assert Linker.offline_link(hub, "http://ÉXAMPLE.COM./p#top") =~ "#top"
  end

  test "ipv6 spellings share one fetch and one file", %{site: _site} do
    hub = "http://[::1]/v6/hub"
    page = "http://[::1]/v6/page"

    spellings = [
      "http://[0::1]/v6/page",
      "http://[0:0:0:0:0:0:0:1]:80/v6/page#a"
    ]

    scope = "spell-ipv6"
    root = tmp("spell-ipv6")
    seen = RequestLog.new()

    crawl(hub, scope, root, single_target(seen, hub, page, spellings))

    assert RequestLog.frequencies(seen) == %{hub => 1, page => 1}

    Enum.each(spellings, fn spelling ->
      assert Store.find({spelling, scope}).body == "PAGE #{page}"
      assert_link_opens(root, hub, spelling)
    end)

    assert Linker.offline_link(hub, "http://[0:0:0:0:0:0:0:1]:80/v6/page#a") =~ "#a"
  end

  test "pages that only look similar stay separate files", %{site: _site} do
    hub = "http://ex.com/apart/hub"

    leaves = [
      %{
        logical: "http://ex.com/apart/a%2fb",
        wire: "http://ex.com/apart/a%2fb",
        spelling: "http://ex.com/apart/a%2Fb"
      },
      %{
        logical: "http://ex.com/apart/a/b",
        wire: "http://ex.com/apart/a/b",
        spelling: "http://ex.com/apart/a/b"
      },
      %{
        logical: "http://ex.com/apart/a//b",
        wire: "http://ex.com/apart/a//b",
        spelling: "http://ex.com/apart/a//b"
      },
      %{
        logical: "http://ex.com/apart/q?a=1&b=2",
        wire: "http://ex.com/apart/q?a=1&b=2",
        spelling: "http://ex.com/apart/q?a=1&b=2"
      },
      %{
        logical: "http://ex.com/apart/q?b=2&a=1",
        wire: "http://ex.com/apart/q?b=2&a=1",
        spelling: "http://ex.com/apart/q?b=2&a=1"
      },
      %{
        logical: "http://ex.com/apart/plus?q=a+b",
        wire: "http://ex.com/apart/plus?q=a+b",
        spelling: "http://ex.com/apart/plus?q=a+b"
      },
      %{
        logical: "http://ex.com/apart/plus?q=a%20b",
        wire: "http://ex.com/apart/plus?q=a%20b",
        spelling: "http://ex.com/apart/plus?q=a%20b"
      },
      %{
        logical: "http://ex.com/apart/empty?",
        wire: "http://ex.com/apart/empty?",
        spelling: "http://ex.com/apart/empty?"
      },
      %{
        logical: "http://ex.com/apart/empty",
        wire: "http://ex.com/apart/empty",
        spelling: "http://ex.com/apart/empty"
      }
    ]

    scope = "spell-apart"
    root = tmp("spell-apart")
    seen = RequestLog.new()
    groups = Map.new(leaves, &{&1.logical, %{wire: &1.wire, spellings: [&1.spelling]}})

    crawl(hub, scope, root, spell_adapter(seen, hub, groups))

    assert RequestLog.frequencies(seen) == Map.put(Map.new(leaves, &{&1.wire, 1}), hub, 1)
    assert Store.ops_count(scope) == length(leaves) + 1
    paths = Enum.map(leaves, &Snapshot.path(&1.spelling))
    assert Enum.uniq(paths) == paths

    Enum.each(leaves, fn leaf ->
      assert File.read!(saved(root, leaf.spelling)) == "PAGE #{leaf.logical}"
      assert Store.find({leaf.logical, scope}).body == "PAGE #{leaf.logical}"
      assert Snapshot.path(leaf.spelling) == Snapshot.path(leaf.logical)
      assert_link_opens(root, hub, leaf.spelling)
    end)
  end

  test "a domain redirect to https is stored under both addresses", %{site: _site} do
    old = "http://ex.com/"
    new = "https://ex.com/"
    scope = "spell-root-https"
    root = tmp("spell-root-https")
    seen = RequestLog.new()

    adapter = fn request ->
      url = request_url(request)
      RequestLog.record(seen, url)

      if request.url.scheme == "http" do
        {request, Req.Response.new(status: 302, headers: [{"location", new}], body: "")}
      else
        {request,
         Req.Response.new(
           status: 200,
           headers: [{"content-type", "text/html"}],
           body: root_page()
         )}
      end
    end

    crawl(old, scope, root, adapter, 1)

    assert RequestLog.frequencies(seen) == %{old => 1, new => 1}
    assert Store.ops_count(scope) == 1
    assert Store.find_processed({old, scope}).body =~ "ROOT"
    assert Store.find_processed({new, scope}).body =~ "ROOT"

    http_file = File.read!(saved(root, old))
    https_file = File.read!(saved(root, new))
    assert http_file =~ "ROOT"
    assert https_file =~ "ROOT"
    assert Snapshot.path(old) != Snapshot.path(new)
    assert http_file =~ Linker.offline_link(old, "https://ex.com/next")
    assert https_file =~ Linker.offline_link(new, "https://ex.com/next")
    assert Snapshot.path(new) =~ "__scheme_https"
  end

  test "a latin-1 page is saved as utf-8 and its link opens the fetched file", %{site: _site} do
    page = "http://ex.com/cs/header"
    cafe = "http://ex.com/cs/café"
    cafe_wire = "http://ex.com/cs/caf%c3%a9"
    scope = "spell-charset-header"
    root = tmp("spell-charset-header")
    seen = RequestLog.new()

    adapter = fn request ->
      url = request_url(request)
      RequestLog.record(seen, url)
      assert :binary.match(url, <<0xE9>>) == :nomatch

      cond do
        url == page ->
          {request,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "text/html; charset=iso-8859-1"}],
             body:
               ~s(<meta charset="utf-8"><a href="caf) <>
                 <<0xE9>> <> ~s(">caf) <> <<0xE9>> <> ~s(</a>)
           )}

        url == cafe_wire ->
          {request,
           Req.Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: "CAFE")}

        true ->
          {request, Req.Response.new(status: 200, body: "UNEXPECTED #{url}")}
      end
    end

    crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe_wire => 1}
    saved = File.read!(saved(root, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert saved =~ "caf%C3%A9"
    assert Store.find_processed({cafe, scope}).body == "CAFE"
    assert_link_opens(root, page, cafe)
    assert File.read!(saved(root, cafe)) == "CAFE"
  end

  test "a meta charset is used when the response does not name one", %{site: _site} do
    page = "http://ex.com/cs/meta"
    cafe = "http://ex.com/cs/café"
    cafe_wire = "http://ex.com/cs/caf%c3%a9"
    scope = "spell-charset-meta"
    root = tmp("spell-charset-meta")
    seen = RequestLog.new()

    adapter = fn request ->
      url = request_url(request)
      RequestLog.record(seen, url)

      cond do
        url == page ->
          {request,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "text/html"}],
             body:
               ~s(<meta charset="iso-8859-1"><a href="caf) <>
                 <<0xE9>> <> ~s(">caf) <> <<0xE9>> <> ~s(</a>)
           )}

        url == cafe_wire ->
          {request,
           Req.Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: "META")}

        true ->
          {request, Req.Response.new(status: 200, body: "UNEXPECTED #{url}")}
      end
    end

    crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe_wire => 1}
    saved = File.read!(saved(root, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert saved =~ "caf%C3%A9"
    assert saved =~ ~s(charset="utf-8")
    refute saved =~ "iso-8859-1"
    assert Store.find_processed({cafe, scope}).body == "META"
    assert_link_opens(root, page, cafe)
  end

  test "an http charset of utf-8 wins over a latin-1 meta tag", %{site: _site} do
    page = "http://ex.com/cs/utf8"
    cafe = "http://ex.com/cs/café"
    cafe_wire = "http://ex.com/cs/caf%c3%a9"
    scope = "spell-charset-utf8"
    root = tmp("spell-charset-utf8")
    seen = RequestLog.new()

    adapter = fn request ->
      url = request_url(request)
      RequestLog.record(seen, url)

      cond do
        url == page ->
          {request,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "text/html; charset=utf-8"}],
             body: ~s(<meta charset="iso-8859-1"><a href="café">café</a>)
           )}

        url == cafe_wire ->
          {request,
           Req.Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: "UTF")}

        true ->
          {request, Req.Response.new(status: 200, body: "UNEXPECTED #{url}")}
      end
    end

    crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe_wire => 1}
    saved = File.read!(saved(root, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert saved =~ "caf%C3%A9"
    refute saved =~ "cafÃ©"
    assert Store.find_processed({cafe, scope}).body == "UTF"
    assert_link_opens(root, page, cafe)
  end

  test "a byte-order mark wins over a latin-1 header", %{site: _site} do
    page = "http://ex.com/cs/bom"
    cafe = "http://ex.com/cs/café"
    cafe_wire = "http://ex.com/cs/caf%c3%a9"
    scope = "spell-charset-bom"
    root = tmp("spell-charset-bom")
    seen = RequestLog.new()

    adapter = fn request ->
      url = request_url(request)
      RequestLog.record(seen, url)

      cond do
        url == page ->
          body =
            <<0xEF, 0xBB, 0xBF>> <> ~s(<meta charset="iso-8859-1"><a href="café">café</a>)

          {request,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "text/html; charset=iso-8859-1"}],
             body: body
           )}

        url == cafe_wire ->
          {request,
           Req.Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: "BOM")}

        true ->
          {request, Req.Response.new(status: 200, body: "UNEXPECTED #{url}")}
      end
    end

    crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe_wire => 1}
    saved = File.read!(saved(root, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert saved =~ "caf%C3%A9"
    assert <<@utf8_bom, html::binary>> = saved
    refute html =~ @utf8_bom
    refute Store.find_processed({page, scope}).body =~ @utf8_bom
    assert Store.find_processed({cafe, scope}).body == "BOM"
    assert_link_opens(root, page, cafe)
  end

  test "a png stays raw bytes and invalid utf-8 does not crash the crawl", %{site: _site} do
    png = "http://ex.com/cs/pic.png"
    bad = "http://ex.com/cs/bad"
    scope = "spell-charset-bytes"
    root = tmp("spell-charset-bytes")

    adapter = fn request ->
      url = request_url(request)

      cond do
        url == png ->
          {request,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "image/png"}],
             body: <<0x89, 0xE9>>
           )}

        url == bad ->
          {request,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "text/html; charset=utf-8"}],
             body: <<0xE9>>
           )}
      end
    end

    crawl(png, scope, root, adapter, 1)
    crawl(bad, scope, root, adapter, 1)

    assert File.read!(saved(root, png)) == <<0x89, 0xE9>>
    assert Store.find_processed({png, scope}).body == <<0x89, 0xE9>>
    assert Store.find_processed({bad, scope}).body == <<0xEF, 0xBF, 0xBD>>
  end

  defp spell_adapter(seen, hub, groups) do
    pages = Map.new(groups, fn {page, %{wire: wire}} -> {wire, page} end)

    html =
      groups
      |> Map.values()
      |> Enum.flat_map(& &1.spellings)
      |> Enum.map_join("", &~s(<a href="#{&1}"></a>))

    fn request ->
      url = request_url(request)
      RequestLog.record(seen, url)

      cond do
        url == hub ->
          {request,
           Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: html)}

        Map.has_key?(pages, url) ->
          {request,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "text/plain"}],
             body: "PAGE #{pages[url]}"
           )}

        true ->
          {request, Req.Response.new(status: 200, body: "UNEXPECTED #{url}")}
      end
    end
  end

  defp single_target(seen, hub, page, spellings) do
    spell_adapter(seen, hub, %{page => %{wire: page, spellings: spellings}})
  end

  defp root_page, do: ~s(<a href="/next"></a>ROOT)

  defp crawl(url, scope, root, adapter, extra \\ []) do
    {max_depths, extra} =
      if is_integer(extra), do: {extra, []}, else: {Keyword.get(extra, :max_depths, 2), extra}

    {:ok, opts} =
      start_crawl(
        url,
        Keyword.merge(
          [
            store: Store,
            scope: scope,
            save_to: root,
            workers: 1,
            max_depths: max_depths,
            respect_robots: false,
            req_options: [adapter: adapter, retry: false]
          ],
          extra
        )
      )

    await_idle(opts)
  end

  defp request_url(request) do
    URI.to_string(request.url)
  end
end
