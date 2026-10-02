defmodule Crawler.CrawlRawTextTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  for tag <- ~w(textarea title) do
    test "literal markup in #{tag} retains a usable following anchor", %{
      site: site,
      url: url,
      req_options: req_options
    } do
      tag = unquote(tag)
      scope = unique_scope("literal-#{tag}")
      root = tmp(scope)
      page = "#{url}/literal-text"
      next = "#{url}/next.html"
      literal = "<#{tag}><script> &amp; <a href=\"next.html\">literal</a></#{tag}>"

      ReqTestSite.expect_once(site, "GET", "/literal-text", fn conn ->
        Plug.Conn.resp(conn, 200, literal <> ~s|<a href="next.html">next</a>|)
      end)

      ReqTestSite.expect_once(site, "GET", "/next.html", fn conn ->
        Plug.Conn.resp(conn, 200, "<p>next page</p>")
      end)

      {:ok, opts} =
        start_crawl(page,
          scope: scope,
          workers: 2,
          retries: 0,
          store: Store,
          save_to: root,
          assets: ["css", "js"],
          req_options: req_options
        )

      on_exit(fn -> Crawler.stop(opts) end)

      wait(fn ->
        refute Crawler.running?(opts)
        assert Store.find_processed({next, scope})
      end)

      assert File.read!(saved(root, page)) ==
               @utf8_bom <>
                 literal <> ~s|<a href="#{Crawler.Linker.offline_link(page, next)}">next</a>|

      assert File.read!(saved(root, next)) == @utf8_bom <> "<p>next page</p>"
      assert_link_opens(root, page, next)
    end
  end

  test "quoted and commented raw openers leave real links and EOF styles usable", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("raw-text-boundaries")
    root = tmp(scope)
    page = "#{url}/raw-text"
    next = "#{url}/next.html"
    script = "#{url}/asset.js"
    image = "#{url}/asset.png"

    ReqTestSite.expect_once(site, "GET", "/raw-text", fn conn ->
      Plug.Conn.resp(conn, 200, """
      <div title="<script>"><!-- <style> --></div>
      <a href="next.html">next</a>
      <script type="module">import "./asset.js";</script>
      <style>.a{background:url("asset.png")}
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/next.html", fn conn ->
      Plug.Conn.resp(conn, 200, "<p>next page</p>")
    end)

    ReqTestSite.expect_once(site, "GET", "/asset.js", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/javascript")
      |> Plug.Conn.resp(200, "export const value = 1;")
    end)

    ReqTestSite.expect_once(site, "GET", "/asset.png", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.resp(200, "image asset")
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 2,
        retries: 0,
        store: Store,
        save_to: root,
        assets: ["css", "js", "images"],
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({next, scope})
      assert Store.find_processed({script, scope})
      assert Store.find_processed({image, scope})
    end)

    assert File.read!(saved(root, page)) =~ ~s|<div title="<script>"><!-- <style> --></div>|
    assert File.read!(saved(root, image)) == "image asset"
    assert_link_opens(root, page, next)
    assert_link_opens(root, page, script)
    assert_link_opens(root, page, image)
  end
end
