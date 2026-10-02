defmodule Crawler.PageSpellingTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Linker
  alias Crawler.Linker.Snapshot
  alias Crawler.RequestLog
  alias Crawler.Store
  alias Crawler.URL

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "equivalent spellings are fetched once and the saved link opens that file", %{site: _site} do
    hub = "http://ex.com/spell/hub"
    space = "http://ex.com/spell/my%20page"
    slash = "http://ex.com/spell/a%2fb"

    groups = %{
      space => [
        "http://ex.com/spell/a/%2e%2e/my%20page#part",
        "http://EX.com./spell/my page",
        "http://ex.com/spell/my%20page",
        "http://ex.com/spell/sub\\..\\my page",
        "http:\\\\ex.com\\spell\\my page",
        "ht\ttp://ex.com/spell/my%20page",
        "http://ex.com/spell/my%20page#other"
      ],
      slash => [
        "http://ex.com/spell/a%2Fb",
        "http://ex.com/spell/a%2fb#z"
      ]
    }

    scope = "spell-same"
    root = tmp("spell-same")
    seen = RequestLog.new()

    crawl(hub, scope, root, spell_adapter(seen, hub, groups))

    assert RequestLog.frequencies(seen) == %{hub => 1, space => 1, slash => 1}
    assert Store.ops_count(scope) == 3

    Enum.each(groups, fn {page, spellings} ->
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

    crawl(hub, scope, root, single_target(seen, hub, page, spellings))

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
      "http://ex.com/apart/a%2Fb",
      "http://ex.com/apart/a/b",
      "http://ex.com/apart/a//b",
      "http://ex.com/apart/q?a=1&b=2",
      "http://ex.com/apart/q?b=2&a=1",
      "http://ex.com/apart/plus?q=a+b",
      "http://ex.com/apart/plus?q=a%20b",
      "http://ex.com/apart/empty?",
      "http://ex.com/apart/empty"
    ]

    scope = "spell-apart"
    root = tmp("spell-apart")
    seen = RequestLog.new()
    groups = Map.new(leaves, &{&1, [&1]})

    crawl(hub, scope, root, spell_adapter(seen, hub, groups))

    assert RequestLog.frequencies(seen) == Map.new([hub | leaves], &{URL.normalize(&1), 1})
    assert Store.ops_count(scope) == length(leaves) + 1
    assert Enum.uniq(Enum.map(leaves, &Snapshot.path/1)) == Enum.map(leaves, &Snapshot.path/1)

    Enum.each(leaves, fn leaf ->
      assert File.read!(saved(root, leaf)) == "PAGE #{URL.normalize(leaf)}"
      assert_link_opens(root, hub, leaf)
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

        url == cafe ->
          {request,
           Req.Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: "CAFE")}

        true ->
          {request, Req.Response.new(status: 200, body: "UNEXPECTED #{url}")}
      end
    end

    crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe => 1}
    saved = File.read!(saved(root, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert saved =~ "caf%C3%A9"
    assert_link_opens(root, page, cafe)
    assert File.read!(saved(root, cafe)) == "CAFE"
  end

  test "a meta charset is used when the response does not name one", %{site: _site} do
    page = "http://ex.com/cs/meta"
    cafe = "http://ex.com/cs/café"
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

        url == cafe ->
          {request,
           Req.Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: "META")}

        true ->
          {request, Req.Response.new(status: 200, body: "UNEXPECTED #{url}")}
      end
    end

    crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe => 1}
    saved = File.read!(saved(root, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert saved =~ "caf%C3%A9"
    assert saved =~ ~s(charset="utf-8")
    refute saved =~ "iso-8859-1"
    assert_link_opens(root, page, cafe)
  end

  test "an http charset of utf-8 wins over a latin-1 meta tag", %{site: _site} do
    page = "http://ex.com/cs/utf8"
    cafe = "http://ex.com/cs/café"
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

        url == cafe ->
          {request,
           Req.Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: "UTF")}

        true ->
          {request, Req.Response.new(status: 200, body: "UNEXPECTED #{url}")}
      end
    end

    crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe => 1}
    saved = File.read!(saved(root, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert saved =~ "caf%C3%A9"
    refute saved =~ "cafÃ©"
    assert_link_opens(root, page, cafe)
  end

  test "a byte-order mark wins over a latin-1 header", %{site: _site} do
    page = "http://ex.com/cs/bom"
    cafe = "http://ex.com/cs/café"
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

        url == cafe ->
          {request,
           Req.Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: "BOM")}

        true ->
          {request, Req.Response.new(status: 200, body: "UNEXPECTED #{url}")}
      end
    end

    crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe => 1}
    saved = File.read!(saved(root, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert saved =~ "caf%C3%A9"
    assert <<@utf8_bom, html::binary>> = saved
    refute html =~ @utf8_bom
    refute Store.find_processed({page, scope}).body =~ @utf8_bom
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
    pages =
      Enum.reduce(groups, %{}, fn {page, spellings}, acc ->
        Enum.reduce(spellings, acc, fn spelling, acc ->
          Map.put(acc, URL.normalize(spelling), URL.normalize(page))
        end)
      end)

    html =
      groups
      |> Map.values()
      |> List.flatten()
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
    spell_adapter(seen, hub, %{page => spellings})
  end

  defp root_page, do: ~s(<a href="/next"></a>ROOT)

  defp crawl(url, scope, root, adapter, max_depths \\ 2) do
    {:ok, opts} =
      Crawler.crawl(url,
        store: Store,
        scope: scope,
        save_to: root,
        workers: 1,
        max_depths: max_depths,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)
  end

  defp request_url(request) do
    request.url |> URI.to_string() |> URL.normalize()
  end
end
