defmodule Crawler.PageSpellingTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.RequestLog
  alias Crawler.Store

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
  end

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
    root = Path.join(tmp("spell-same"), "archive")
    seen = RequestLog.new()

    export = crawl(hub, scope, root, spell_adapter(seen, hub, groups))

    assert RequestLog.frequencies(seen) == %{hub => 1, space => 1, slash => 1}
    assert Store.ops_count(scope) == 3
    assert_spelling_links(export, hub, groups |> Map.values() |> Enum.flat_map(& &1.spellings))

    Enum.each(groups, fn {page, %{spellings: spellings}} ->
      Enum.each(spellings, fn spelling ->
        assert Store.find({spelling, scope}).body == "PAGE #{page}"
      end)
    end)
  end

  test "a unicode host and its punycode spelling share one file", %{site: _site} do
    hub = "http://xn--xample-9ua.com/idn/hub"
    page = "http://xn--xample-9ua.com/p"
    spellings = ["http://éxample.com/p", "http://ÉXAMPLE.COM/p#top"]
    scope = "spell-idn"
    root = Path.join(tmp("spell-idn"), "archive")
    seen = RequestLog.new()

    export = crawl(hub, scope, root, single_target(seen, hub, page, spellings))

    assert RequestLog.frequencies(seen) == %{hub => 1, page => 1}
    assert Store.find({page, scope}).body == "PAGE #{page}"
    assert_spelling_links(export, hub, spellings)

    Enum.each(spellings, fn spelling ->
      assert Store.find({spelling, scope}).body == "PAGE #{page}"
    end)
  end

  test "ipv6 spellings share one fetch and one file", %{site: _site} do
    hub = "http://[::1]/v6/hub"
    page = "http://[::1]/v6/page"

    spellings = [
      "http://[0::1]/v6/page",
      "http://[0:0:0:0:0:0:0:1]:80/v6/page#a"
    ]

    scope = "spell-ipv6"
    root = Path.join(tmp("spell-ipv6"), "archive")
    seen = RequestLog.new()

    export = crawl(hub, scope, root, single_target(seen, hub, page, spellings))

    assert RequestLog.frequencies(seen) == %{hub => 1, page => 1}
    assert_spelling_links(export, hub, spellings)

    Enum.each(spellings, fn spelling ->
      assert Store.find({spelling, scope}).body == "PAGE #{page}"
    end)
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
    root = Path.join(tmp("spell-apart"), "archive")
    seen = RequestLog.new()
    groups = Map.new(leaves, &{&1.logical, %{wire: &1.wire, spellings: [&1.spelling]}})

    adapter = spell_adapter(seen, hub, groups)
    export = crawl(hub, scope, root, adapter, req_options: [adapter: adapter, retry: false])

    assert RequestLog.frequencies(seen) == Map.put(Map.new(leaves, &{&1.wire, 1}), hub, 1)
    assert Store.ops_count(scope) == length(leaves) + 1
    source = resource_for_url(export, hub)

    paths =
      Enum.map(Enum.with_index(leaves), fn {_leaf, index} ->
        edge_target(export, source, index)["path"]
      end)

    assert Enum.uniq(paths) == paths
    assert_spelling_links(export, hub, groups |> Map.values() |> Enum.flat_map(& &1.spellings))

    Enum.each(leaves, fn leaf ->
      assert Store.find({leaf.logical, scope}).body == "PAGE #{leaf.logical}"
    end)
  end

  test "a domain redirect to https is stored under both addresses", %{site: _site} do
    old = "http://ex.com/"
    new = "https://ex.com/"
    scope = "spell-root-https"
    root = Path.join(tmp("spell-root-https"), "archive")
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

    export = crawl(old, scope, root, adapter, 1)

    assert RequestLog.frequencies(seen) == %{old => 1, new => 1}
    assert Store.ops_count(scope) == 1
    assert Store.find_processed({old, scope}).body =~ "ROOT"
    assert Store.find_processed({new, scope}).body =~ "ROOT"

    source = resource_for_url(export, new)
    body = read_resource(export, source)
    assert body =~ "ROOT"
    assert ["https://ex.com/next"] == Floki.attribute(Floki.parse_document!(body), "a", "href")
  end

  test "a latin-1 page is saved as utf-8 and its link opens the fetched file", %{site: _site} do
    page = "http://ex.com/cs/header"
    cafe = "http://ex.com/cs/café"
    cafe_wire = "http://ex.com/cs/caf%c3%a9"
    scope = "spell-charset-header"
    root = Path.join(tmp("spell-charset-header"), "archive")
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

    export = crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe_wire => 1}
    saved = read_resource(export, resource_for_url(export, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert Store.find_processed({cafe, scope}).body == "CAFE"
    source = resource_for_url(export, page)
    target = reference_target(export, source, cafe)
    assert [href] = Floki.attribute(Floki.parse_document!(saved), "a", "href")
    assert_opens(export, source, target, href)
    assert read_resource(export, resource_for_url(export, cafe)) == "CAFE"
  end

  test "a meta charset is used when the response does not name one", %{site: _site} do
    page = "http://ex.com/cs/meta"
    cafe = "http://ex.com/cs/café"
    cafe_wire = "http://ex.com/cs/caf%c3%a9"
    scope = "spell-charset-meta"
    root = Path.join(tmp("spell-charset-meta"), "archive")
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

    export = crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe_wire => 1}
    saved = read_resource(export, resource_for_url(export, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert saved =~ ~s(charset="utf-8")
    refute saved =~ "iso-8859-1"
    assert Store.find_processed({cafe, scope}).body == "META"
    source = resource_for_url(export, page)
    target = reference_target(export, source, cafe)
    assert [href] = Floki.attribute(Floki.parse_document!(saved), "a", "href")
    assert_opens(export, source, target, href)
    assert read_resource(export, target) == "META"
  end

  test "an http charset of utf-8 wins over a latin-1 meta tag", %{site: _site} do
    page = "http://ex.com/cs/utf8"
    cafe = "http://ex.com/cs/café"
    cafe_wire = "http://ex.com/cs/caf%c3%a9"
    scope = "spell-charset-utf8"
    root = Path.join(tmp("spell-charset-utf8"), "archive")
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

    export = crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe_wire => 1}
    saved = read_resource(export, resource_for_url(export, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    refute saved =~ "cafÃ©"
    assert Store.find_processed({cafe, scope}).body == "UTF"
    source = resource_for_url(export, page)
    target = reference_target(export, source, cafe)
    assert [href] = Floki.attribute(Floki.parse_document!(saved), "a", "href")
    assert_opens(export, source, target, href)
    assert read_resource(export, target) == "UTF"
  end

  test "a byte-order mark wins over a latin-1 header", %{site: _site} do
    page = "http://ex.com/cs/bom"
    cafe = "http://ex.com/cs/café"
    cafe_wire = "http://ex.com/cs/caf%c3%a9"
    scope = "spell-charset-bom"
    root = Path.join(tmp("spell-charset-bom"), "archive")
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

    export = crawl(page, scope, root, adapter)

    assert RequestLog.frequencies(seen) == %{page => 1, cafe_wire => 1}
    saved = read_resource(export, resource_for_url(export, page))
    assert String.valid?(saved)
    assert saved =~ "café"
    assert <<@utf8_bom, html::binary>> = saved
    refute html =~ @utf8_bom
    refute Store.find_processed({page, scope}).body =~ @utf8_bom
    assert Store.find_processed({cafe, scope}).body == "BOM"
    source = resource_for_url(export, page)
    target = reference_target(export, source, cafe)
    assert [href] = Floki.attribute(Floki.parse_document!(saved), "a", "href")
    assert_opens(export, source, target, href)
    assert read_resource(export, target) == "BOM"
  end

  test "a png stays raw bytes and invalid utf-8 does not crash the crawl", %{site: _site} do
    png = "http://ex.com/cs/pic.png"
    bad = "http://ex.com/cs/bad"
    scope = "spell-charset-bytes"
    root = Path.join(tmp("spell-charset-bytes"), "archive")

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

    export = crawl(png, scope, root, adapter, 1)
    bad_export = crawl(bad, scope <> "-bad", root <> "-bad", adapter, 1)

    assert read_resource(export, resource_for_url(export, png)) == <<0x89, 0xE9>>
    assert Store.find_processed({png, scope}).body == <<0x89, 0xE9>>
    assert Store.find_processed({bad, scope <> "-bad"}).body == <<0xEF, 0xBF, 0xBD>>

    assert read_resource(bad_export, resource_for_url(bad_export, bad)) ==
             @utf8_bom <> <<0xEF, 0xBF, 0xBD>>
  end

  defp assert_spelling_links(export, hub, spellings) do
    source = resource_for_url(export, hub)
    hrefs = Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")
    assert length(hrefs) == length(spellings)

    targets =
      for {{href, spelling}, index} <- Enum.with_index(Enum.zip(hrefs, spellings)) do
        target = edge_target(export, source, index)
        assert {:ok, online} = Crawler.Export.Paths.online(Crawler.URL.normalize(spelling))
        assert target["url"] == online
        fragment = URI.parse(spelling).fragment
        assert_opens(export, source, target, href, if(fragment, do: "#" <> fragment, else: ""))
        assert read_resource(export, target) == "PAGE #{online}"
        {online, target["id"]}
      end

    for {_url, ids} <- Enum.group_by(targets, &elem(&1, 0), &elem(&1, 1)) do
      assert length(Enum.uniq(ids)) == 1
    end
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
            max_body: 1_048_576,
            max_analysis_bytes: 16_000_000,
            max_css_work: 5_000,
            max_css_pictures: 1_000,
            max_depths: max_depths,
            respect_robots: false,
            req_options: plug_options(adapter)
          ],
          extra
        )
      )

    ready_export(opts)
  end

  defp plug_options(adapter) do
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      request =
        Req.new(
          url: %URI{
            scheme: Atom.to_string(conn.scheme),
            host: conn.host,
            port: conn.port,
            path: conn.request_path,
            query: if(conn.query_string == "", do: nil, else: conn.query_string)
          },
          headers: conn.req_headers
        )

      {_request, response} = adapter.(request)
      conn = %{conn | resp_headers: Req.get_headers_list(response)}
      Plug.Conn.send_resp(conn, response.status, response.body || "")
    end)

    [plug: {Req.Test, name}, retry: false]
  end

  defp request_url(request) do
    URI.to_string(request.url)
  end
end
