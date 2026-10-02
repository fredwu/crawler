defmodule Crawler.RedirectPolicyTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store

  import Crawler.RedirectHelpers
  import Crawler.SnapshotHelpers
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.RedirectHelpers.HostFilter

  defmodule SecretFilter do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(url, _opts) do
      path = URI.parse(url).path || ""
      {:ok, not String.starts_with?(path, "/id/secret")}
    end
  end

  defmodule BoundaryFilter do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(url, _opts) do
      uri = URI.parse(url)
      path = uri.path || ""

      {:ok, uri.host == "ex.com" and not String.starts_with?(path, "/id/secret")}
    end
  end

  test "a rejected redirect is not saved, followed, or retried", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-reject")
    scope = "page-identity-reject"
    public = "#{url}/id/public"
    secret = "#{url}/id/secret"
    nxt = "#{url}/id/next"
    hits = new_count()

    ReqTestSite.expect(site, "GET", "/id/public", fn conn ->
      bump(hits)

      conn
      |> Plug.Conn.put_resp_header("location", secret)
      |> Plug.Conn.resp(302, "")
    end)

    opts =
      crawl(public,
        scope: scope,
        workers: 1,
        retries: 2,
        max_depths: 2,
        save_to: root,
        url_filter: SecretFilter,
        req_options: req_options
      )

    await_idle(opts)

    assert count(hits) == 1
    assert Store.ops_count(scope) == 0
    refute Store.find({public, scope})
    refute Store.find({secret, scope})
    refute File.exists?(saved(root, public))
    refute File.exists?(saved(root, secret))

    html(site, "/id/secret", ~s(<p>SECRET</p><a href="next">next</a>))
    text(site, "/id/next", "NEXT")

    again =
      crawl(public,
        scope: scope,
        workers: 1,
        max_depths: 2,
        save_to: root,
        url_filter: UrlFilter,
        req_options: req_options
      )

    await_idle(again)

    assert count(hits) == 2
    assert File.read!(saved(root, public)) =~ "SECRET"
    assert File.read!(saved(root, secret)) =~ "SECRET"
    assert_link_opens(root, public, nxt)
    assert_link_opens(root, secret, nxt)
    assert Store.find_processed({public, scope})
    assert Store.find_processed({secret, scope})
    assert Store.find_processed({nxt, scope})
  end

  test "a redirect to a rejected host or scheme is not fetched" do
    root = tmp("page-identity-foreign")
    scope = "page-identity-foreign"
    hub = "http://ex.com/id/hub"

    sources = [
      {"http://ex.com/id/js", "javascript:alert(1)"},
      {"http://ex.com/id/ftp", "ftp://files.example/secret"},
      {"http://ex.com/id/evil", "http://evil.test/nope"},
      {"http://ex.com/id/proto", "//evil.test/nope"}
    ]

    hits = RequestLog.new()

    adapter = fn request ->
      RequestLog.record(hits, {request.url.host, request.url.path})

      source =
        Enum.find(sources, fn {url, _location} ->
          request.url.path == URI.parse(url).path
        end)

      if source do
        {_url, location} = source
        redirect(request, location)
      else
        if request.url.path == "/id/hub" do
          body = Enum.map_join(sources, "", fn {url, _} -> ~s(<a href="#{url}"></a>) end)
          html_response(request, body)
        else
          text_response(request, "LEAKED")
        end
      end
    end

    opts =
      crawl(hub,
        scope: scope,
        workers: 1,
        retries: 2,
        max_depths: 2,
        save_to: root,
        url_filter: HostFilter,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert hits |> RequestLog.entries() |> Enum.frequencies() == %{
             {"ex.com", "/id/hub"} => 1,
             {"ex.com", "/id/js"} => 1,
             {"ex.com", "/id/ftp"} => 1,
             {"ex.com", "/id/evil"} => 1,
             {"ex.com", "/id/proto"} => 1
           }

    assert Store.ops_count(scope) == 1
    refute File.read!(saved(root, hub)) =~ "LEAKED"

    Enum.each(sources, fn {url, _location} ->
      refute Store.find({url, scope})
      refute File.exists?(saved(root, url))
    end)

    refute Store.find({"http://evil.test/nope", scope})
    refute Store.find({"javascript:alert(1)", scope})
  end

  test "a relative location outside the crawl is not saved" do
    root = tmp("page-identity-rel-reject")
    scope = "page-identity-rel-reject"
    hub = "http://ex.com/id/hub"

    sources = [
      {"http://ex.com/id/gate", "secret"},
      {"http://ex.com/id/dots", "/id/public/../secret"},
      {"http://ex.com/id/proto", "//evil.test/nope"}
    ]

    hits = RequestLog.new()

    adapter = fn request ->
      RequestLog.record(hits, {request.url.host, request.url.path})

      source =
        Enum.find(sources, fn {url, _location} ->
          request.url.path == URI.parse(url).path
        end)

      cond do
        source ->
          {_url, location} = source
          redirect(request, location)

        request.url.path == "/id/hub" ->
          body = Enum.map_join(sources, "", fn {url, _} -> ~s(<a href="#{url}"></a>) end)
          html_response(request, body)

        true ->
          text_response(request, "LEAKED")
      end
    end

    opts =
      crawl(hub,
        scope: scope,
        workers: 1,
        retries: 2,
        max_depths: 2,
        save_to: root,
        url_filter: BoundaryFilter,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert hits |> RequestLog.entries() |> Enum.frequencies() == %{
             {"ex.com", "/id/hub"} => 1,
             {"ex.com", "/id/gate"} => 1,
             {"ex.com", "/id/dots"} => 1,
             {"ex.com", "/id/proto"} => 1
           }

    assert Store.ops_count(scope) == 1
    refute File.read!(saved(root, hub)) =~ "LEAKED"

    Enum.each(sources, fn {url, _location} ->
      refute Store.find({url, scope})
      refute File.exists?(saved(root, url))
    end)

    refute Store.find({"http://ex.com/id/secret", scope})
    refute Store.find({"http://evil.test/nope", scope})
    refute File.exists?(saved(root, "http://ex.com/id/secret"))
    refute File.exists?(saved(root, "http://evil.test/nope"))
  end
end
