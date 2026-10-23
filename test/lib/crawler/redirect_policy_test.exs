defmodule Crawler.RedirectPolicyTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store

  import Crawler.RedirectHelpers
  import Crawler.ManagedSnapshotHelpers
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
    parent = tmp("page-identity-reject-#{System.os_time(:nanosecond)}")
    on_exit(fn -> File.rm_rf(parent) end)
    root = Path.join(parent, "rejected")
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
    rejected = ready_export(opts)
    assert rejected.manifest["resources"] == []

    html(site, "/id/secret", ~s(<p>SECRET</p><a href="next">next</a>))
    text(site, "/id/next", "NEXT")

    root = Path.join(Path.dirname(root), "accepted")

    again =
      crawl(public,
        force: true,
        scope: scope,
        workers: 1,
        max_depths: 2,
        save_to: root,
        url_filter: UrlFilter,
        req_options: req_options
      )

    await_idle(again)

    assert count(hits) == 2
    export = ready_export(again)
    public_resource = resource_for_url(export, secret)
    next_resource = reference_target(export, public_resource, nxt)
    body = read_resource(export, public_resource)
    assert body =~ "SECRET"
    assert read_resource(export, next_resource) == "NEXT"
    assert [href] = Regex.run(~r/<a href="([^"]+)">/, body, capture: :all_but_first)
    assert_opens(export, public_resource, next_resource, href)
    assert public_resource["url"] == secret
    assert Store.find_processed({public, scope})
    assert Store.find_processed({secret, scope})
    assert Store.find_processed({nxt, scope})
  end

  test "a redirect to a rejected host or scheme is not fetched" do
    parent = tmp("page-identity-foreign-#{System.os_time(:nanosecond)}")
    on_exit(fn -> File.rm_rf(parent) end)
    root = Path.join(parent, "export")
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
    export = ready_export(opts)
    hub_resource = resource_for_url(export, hub)
    body = read_resource(export, hub_resource)
    refute body =~ "LEAKED"
    assert length(export.manifest["resources"]) == 1

    Enum.each(sources, fn {url, _} -> assert body =~ url end)

    Enum.each(sources, fn {url, _location} ->
      refute Store.find({url, scope})
      refute Enum.any?(export.manifest["resources"], &(&1["url"] == url))
    end)

    refute Store.find({"http://evil.test/nope", scope})
    refute Store.find({"javascript:alert(1)", scope})
  end

  test "a relative location outside the crawl is not saved" do
    parent = tmp("page-identity-rel-reject-#{System.os_time(:nanosecond)}")
    on_exit(fn -> File.rm_rf(parent) end)
    root = Path.join(parent, "export")
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
    export = ready_export(opts)
    hub_resource = resource_for_url(export, hub)
    body = read_resource(export, hub_resource)
    refute body =~ "LEAKED"
    assert length(export.manifest["resources"]) == 1

    Enum.each(sources, fn {url, _} -> assert body =~ url end)

    Enum.each(sources, fn {url, _location} ->
      refute Store.find({url, scope})
      refute Enum.any?(export.manifest["resources"], &(&1["url"] == url))
    end)

    refute Store.find({"http://ex.com/id/secret", scope})
    refute Store.find({"http://evil.test/nope", scope})

    refute Enum.any?(
             export.manifest["resources"],
             &(&1["url"] in ["http://ex.com/id/secret", "http://evil.test/nope"])
           )
  end
end
