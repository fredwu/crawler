defmodule Crawler.PageIdentityTest do
  use Crawler.TestCase, async: false

  alias Crawler.Fetcher
  alias Crawler.Fetcher.Modifier
  alias Crawler.Fetcher.Retrier
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.Linker
  alias Crawler.Linker.Snapshot
  alias Crawler.Store

  defmodule HostFilter do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(url, _opts) do
      {:ok, URI.parse(url).host == "ex.com"}
    end
  end

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

  test "a redirect is saved at the requested address and the landing address", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-redirect")
    scope = "page-identity-redirect"
    hub = "#{url}/id/hub"
    old = "#{url}/id/old"
    new = "#{url}/id/dir/new"
    nxt = "#{url}/id/dir/next"
    later = "#{url}/id/later"

    html(site, "/id/hub", ~s(<a href="#{old}">old</a><a href="#{later}">later</a>))

    ReqTestSite.expect_once(site, "GET", "/id/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/id/dir/new", ~s(<p>LANDED</p><a href="next">next</a>))
    text(site, "/id/dir/next", "NEXT")
    html(site, "/id/later", ~s(<a href="#{new}">landed</a>))

    opts =
      crawl(hub,
        scope: scope,
        workers: 1,
        max_depths: 3,
        save_to: root,
        req_options: req_options
      )

    await_idle(opts)

    assert Store.ops_count(scope) == 4
    assert Store.find_processed({old, scope}).body =~ "LANDED"
    assert Store.find_processed({new, scope}).body =~ "LANDED"
    assert Store.find_processed({nxt, scope}).body == "NEXT"

    old_href = Linker.offline_link(old, nxt)
    new_href = Linker.offline_link(new, nxt)
    refute old_href == new_href
    assert File.read!(saved(root, old)) =~ "LANDED"
    assert File.read!(saved(root, new)) =~ "LANDED"
    assert_link_opens(root, old, nxt)
    assert_link_opens(root, new, nxt)
    assert_link_opens(root, later, new)
  end

  test "a relative location is saved at both addresses", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-relative")
    scope = "page-identity-relative"
    old = "#{url}/id/rel/old"
    new = "#{url}/id/rel/dir/new"
    nxt = "#{url}/id/rel/dir/next"

    ReqTestSite.expect_once(site, "GET", "/id/rel/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "dir/new")
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/id/rel/dir/new", ~s(<p>LANDED</p><a href="next">next</a>))
    text(site, "/id/rel/dir/next", "NEXT")

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_depths: 2,
        save_to: root,
        req_options: req_options
      )

    await_idle(opts)

    assert Store.ops_count(scope) == 2
    assert Store.find_processed({old, scope}).body =~ "LANDED"
    assert Store.find_processed({new, scope}).body =~ "LANDED"
    refute File.read!(saved(root, old)) == File.read!(saved(root, new))
    assert_link_opens(root, old, nxt)
    assert_link_opens(root, new, nxt)
  end

  test "an absolute-path location is saved at both addresses", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-abs-location")
    scope = "page-identity-abs-location"
    old = "#{url}/id/abs/old"
    new = "#{url}/id/dir/nested/new"
    nxt = "#{url}/id/dir/nested/next"

    ReqTestSite.expect_once(site, "GET", "/id/abs/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/id/dir/nested/new")
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/id/dir/nested/new", ~s(<p>LANDED</p><a href="next">next</a>))
    text(site, "/id/dir/nested/next", "NEXT")

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_depths: 2,
        save_to: root,
        req_options: req_options
      )

    await_idle(opts)

    assert Store.ops_count(scope) == 2
    assert Store.find_processed({old, scope}).body =~ "LANDED"
    assert Store.find_processed({new, scope}).body =~ "LANDED"
    refute File.read!(saved(root, old)) == File.read!(saved(root, new))
    assert_link_opens(root, old, nxt)
    assert_link_opens(root, new, nxt)
  end

  test "http, https, userinfo, an empty query, and path case do not share a file" do
    root = tmp("page-identity-distinct")
    scope = "page-identity-distinct"
    hub = "http://ex.com/id/hub"

    leaves = [
      "http://ex.com/id/scheme",
      "https://ex.com/id/scheme",
      "http://a:b@ex.com/id/secret",
      "http://A:B@ex.com/id/secret",
      "http://ex.com/id/secret",
      "http://ex.com/id/search",
      "http://ex.com/id/search?",
      "http://ex.com/id/search?q=1",
      "http://ex.com/id/search?Q=1",
      "http://ex.com/id/docs",
      "http://ex.com/id/Docs"
    ]

    seen = new_log()

    adapter = fn request ->
      uri = request.url
      log(seen, {uri.scheme, uri.userinfo, uri.path, uri.query})

      body =
        if uri.path == "/id/hub" do
          Enum.map_join(leaves, "", fn leaf -> ~s(<a href="#{leaf}"></a>) end)
        else
          "body:#{uri.scheme}:#{uri.userinfo}:#{uri.path}:#{inspect(uri.query)}:#{System.unique_integer([:positive])}"
        end

      {request,
       Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
    end

    opts =
      crawl(hub,
        scope: scope,
        workers: 1,
        max_depths: 2,
        save_to: root,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert Store.ops_count(scope) == length(leaves) + 1
    requests = logged(seen)
    assert length(requests) == length(leaves) + 1

    Enum.each(leaves, fn leaf ->
      page = Store.find_processed({leaf, scope})
      assert page.body == File.read!(saved(root, leaf))
      assert_link_opens(root, hub, leaf)
    end)

    refute File.read!(saved(root, "http://ex.com/id/scheme")) ==
             File.read!(saved(root, "https://ex.com/id/scheme"))

    refute File.read!(saved(root, "http://a:b@ex.com/id/secret")) ==
             File.read!(saved(root, "http://ex.com/id/secret"))

    refute File.read!(saved(root, "http://ex.com/id/search")) ==
             File.read!(saved(root, "http://ex.com/id/search?"))

    refute File.read!(saved(root, "http://ex.com/id/docs")) ==
             File.read!(saved(root, "http://ex.com/id/Docs"))

    paths = Enum.map(leaves, &String.downcase(Snapshot.path(&1)))
    assert paths == Enum.uniq(paths)

    assert {"https", nil, "/id/scheme", nil} in requests
    assert {"http", "a:b", "/id/secret", nil} in requests
    assert {"http", "A:B", "/id/secret", nil} in requests
    assert {"http", nil, "/id/search", nil} in requests
    assert {"http", nil, "/id/search", ""} in requests
  end

  test "a redirect to a bare question mark stays a different page" do
    root = tmp("page-identity-empty-query")
    scope = "page-identity-empty-query"
    old = "http://ex.com/id/old"
    empty = "http://ex.com/id/search?"
    bare = "http://ex.com/id/search"
    queries = new_log()

    adapter = fn request ->
      uri = request.url
      log(queries, {uri.path, uri.query})

      cond do
        uri.path == "/id/old" ->
          redirect(request, empty)

        uri.path == "/id/search" and uri.query == "" ->
          html_response(request, ~s(<p>EMPTY</p><a href="#{bare}">bare</a>))

        uri.path == "/id/search" and uri.query == nil ->
          text_response(request, "BARE")

        true ->
          text_response(request, "UNEXPECTED")
      end
    end

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_depths: 2,
        save_to: root,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert queries |> logged() |> Enum.frequencies() == %{
             {"/id/old", nil} => 1,
             {"/id/search", ""} => 1,
             {"/id/search", nil} => 1
           }

    assert File.read!(saved(root, old)) =~ "EMPTY"
    assert File.read!(saved(root, empty)) =~ "EMPTY"
    assert File.read!(saved(root, bare)) == "BARE"
    assert Snapshot.path(empty) != Snapshot.path(bare)
    assert_link_opens(root, old, bare)
    assert_link_opens(root, empty, bare)
    assert Store.find_processed({empty, scope})
    assert Store.find_processed({bare, scope})
    assert Store.ops_count(scope) == 2
  end

  test "an allowed redirect to https is saved under both addresses" do
    root = tmp("page-identity-https-redirect")
    scope = "page-identity-https-redirect"
    old = "http://ex.com/id/old"
    new = "https://ex.com/id/dir/new"
    nxt = "https://ex.com/id/dir/next"
    hits = new_log()

    adapter = fn request ->
      uri = request.url
      log(hits, {uri.scheme, uri.path})

      cond do
        uri.scheme == "http" and uri.path == "/id/old" ->
          redirect(request, new)

        uri.scheme == "https" and uri.path == "/id/dir/new" ->
          html_response(request, ~s(<p>LANDED</p><a href="next">next</a>))

        uri.scheme == "https" and uri.path == "/id/dir/next" ->
          text_response(request, "NEXT")

        true ->
          text_response(request, "UNEXPECTED")
      end
    end

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_depths: 2,
        save_to: root,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert hits |> logged() |> Enum.frequencies() == %{
             {"http", "/id/old"} => 1,
             {"https", "/id/dir/new"} => 1,
             {"https", "/id/dir/next"} => 1
           }

    assert Snapshot.path(new) =~ "__scheme_https"
    assert File.read!(saved(root, old)) =~ "LANDED"
    assert File.read!(saved(root, new)) =~ "LANDED"
    refute File.read!(saved(root, old)) == File.read!(saved(root, new))
    assert_link_opens(root, old, nxt)
    assert_link_opens(root, new, nxt)
    assert Store.find_processed({new, scope})
    assert Store.ops_count(scope) == 2
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

    hits = new_log()

    adapter = fn request ->
      log(hits, {request.url.host, request.url.path})

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

    assert hits |> logged() |> Enum.frequencies() == %{
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

    hits = new_log()

    adapter = fn request ->
      log(hits, {request.url.host, request.url.path})

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

    assert hits |> logged() |> Enum.frequencies() == %{
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

  test "redirect: false returns the redirect response" do
    scope = "page-identity-no-follow"
    seen = new_log()

    pages = %{
      "/id/no-js" => "javascript:alert(1)",
      "/id/no-filter" => "http://evil.test/secret"
    }

    adapter = fn request ->
      log(seen, {request.url.host, request.url.path})
      location = Map.get(pages, request.url.path, "http://ex.com/id/followed")

      {request, Req.Response.new(status: 302, headers: [{"location", location}], body: "")}
    end

    Enum.each(pages, fn {path, _location} ->
      page = "http://ex.com#{path}"

      result =
        fetcher(%{
          url: page,
          scope: scope,
          retries: 2,
          url_filter: HostFilter,
          req_options: [adapter: adapter, retry: false, redirect: false]
        })

      assert result == {:warn, "Failed to fetch #{page}, status code: 302"}
      refute Store.find({page, scope}).body
    end)

    assert logged(seen) |> Enum.frequencies() == %{
             {"ex.com", "/id/no-js"} => 1,
             {"ex.com", "/id/no-filter"} => 1
           }
  end

  test "max_redirects: 0 reports too many redirects for a rejected location" do
    scope = "page-identity-cap"
    seen = new_log()

    pages = %{
      "/id/cap-js" => "javascript:alert(1)",
      "/id/cap-evil" => "http://evil.test/secret"
    }

    adapter = fn request ->
      log(seen, {request.url.host, request.url.path})
      location = Map.get(pages, request.url.path, "http://evil.test/secret")

      {request, Req.Response.new(status: 302, headers: [{"location", location}], body: "")}
    end

    Enum.each(pages, fn {path, _location} ->
      page = "http://ex.com#{path}"

      result =
        fetcher(%{
          url: page,
          scope: scope,
          retries: 1,
          url_filter: HostFilter,
          req_options: [adapter: adapter, retry: false, max_redirects: 0]
        })

      assert result == {:error, "Failed to fetch #{page}, reason: too many redirects (0)"}
      refute Store.find({page, scope}).body
    end)

    assert logged(seen) |> Enum.frequencies() == %{
             {"ex.com", "/id/cap-js"} => 2,
             {"ex.com", "/id/cap-evil"} => 2
           }
  end

  test "a redirect past the hop limit is not a rejected redirect" do
    scope = "page-identity-chain"
    seen = new_log()
    page = "http://ex.com/id/chain/0"

    adapter = fn request ->
      log(seen, {request.url.host, request.url.path})

      location =
        case request.url.path do
          "/id/chain/" <> n ->
            step = String.to_integer(n)

            if step < 5 do
              "http://ex.com/id/chain/#{step + 1}"
            else
              "http://evil.test/nope"
            end

          _ ->
            "http://evil.test/nope"
        end

      {request, Req.Response.new(status: 302, headers: [{"location", location}], body: "")}
    end

    result =
      fetcher(%{
        url: page,
        scope: scope,
        retries: 0,
        url_filter: HostFilter,
        req_options: [adapter: adapter, retry: false, max_redirects: 5]
      })

    assert result == {:error, "Failed to fetch #{page}, reason: too many redirects (5)"}

    assert logged(seen) |> Enum.frequencies() ==
             Map.new(0..5, fn step -> {{"ex.com", "/id/chain/#{step}"}, 1} end)
  end

  test "a blank location is not followed" do
    scope = "page-identity-blank"
    seen = new_log()

    pages = %{
      "/id/blank-space" => " ",
      "/id/blank-tab" => "\t"
    }

    adapter = fn request ->
      log(seen, {request.url.host, request.url.path})
      location = Map.get(pages, request.url.path, "http://evil.test/secret")

      {request, Req.Response.new(status: 302, headers: [{"location", location}], body: "")}
    end

    Enum.each(pages, fn {path, _location} ->
      page = "http://ex.com#{path}"

      result =
        fetcher(%{
          url: page,
          scope: scope,
          retries: 2,
          url_filter: HostFilter,
          req_options: [adapter: adapter, retry: false]
        })

      assert result == {:warn, "Failed to fetch #{page}, status code: 302"}
      refute Store.find({page, scope}).body
    end)

    assert logged(seen) |> Enum.frequencies() == %{
             {"ex.com", "/id/blank-space"} => 1,
             {"ex.com", "/id/blank-tab"} => 1
           }
  end

  test "a padded location is trimmed before the allow check" do
    scope = "page-identity-padded"
    seen = new_log()
    page = "http://ex.com/id/padded"

    adapter = fn request ->
      log(seen, {request.url.host, request.url.path})

      {request,
       Req.Response.new(
         status: 302,
         headers: [{"location", " http://evil.test/secret "}],
         body: ""
       )}
    end

    result =
      fetcher(%{
        url: page,
        scope: scope,
        retries: 2,
        url_filter: HostFilter,
        req_options: [adapter: adapter, retry: false]
      })

    assert result ==
             {:warn, "Redirect rejected for #{page} to http://evil.test/secret"}

    assert logged(seen) == [{"ex.com", "/id/padded"}]
  end

  test "a redirect hop is not a second page", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-budget")
    scope = "page-identity-budget"
    old = "#{url}/id/budget/old"
    new = "#{url}/id/budget/new"

    ReqTestSite.expect_once(site, "GET", "/id/budget/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/id/budget/new", ~s(<p>PAGE</p><a href="#{url}/id/budget/next">next</a>))

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_pages: 1,
        max_depths: 3,
        save_to: root,
        req_options: req_options
      )

    await_idle(opts)

    assert File.read!(saved(root, old)) =~ "PAGE"
    assert File.read!(saved(root, new)) =~ "PAGE"
    assert Store.ops_count(scope) == 1
    refute Store.find({"#{url}/id/budget/next", scope})
  end

  test "a redirect still fetches a landing page that was already stored", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-alias")
    scope = "page-identity-alias"
    old = "#{url}/id/alias/old"
    new = "#{url}/id/alias/new"
    hits = new_count()

    ReqTestSite.expect(site, "GET", "/id/alias/new", fn conn ->
      bump(hits)
      Plug.Conn.resp(conn, 200, "PAGE")
    end)

    first = crawl(new, scope: scope, workers: 1, save_to: root, req_options: req_options)
    await_idle(first)
    assert count(hits) == 1

    ReqTestSite.expect_once(site, "GET", "/id/alias/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    second = crawl(old, scope: scope, workers: 1, save_to: root, req_options: req_options)
    await_idle(second)

    assert count(hits) == 2
    assert File.read!(saved(root, old)) == "PAGE"
    assert File.read!(saved(root, new)) == "PAGE"
    assert Store.find_processed({old, scope}).body == "PAGE"
    assert Store.ops_count(scope) == 2
  end

  test "a redirect past the link depth is saved and its links are not followed", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-depth")
    scope = "page-identity-depth"
    old = "#{url}/id/depth/old"
    new = "#{url}/id/depth/new"

    ReqTestSite.expect_once(site, "GET", "/id/depth/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/id/depth/new", ~s(<p>LANDED</p><a href="#{url}/id/depth/next">next</a>))

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_depths: 1,
        save_to: root,
        req_options: req_options
      )

    await_idle(opts)

    assert File.read!(saved(root, old)) =~ "LANDED"
    assert File.read!(saved(root, new)) =~ "LANDED"
    assert Store.ops_count(scope) == 1
    refute Store.find({"#{url}/id/depth/next", scope})
  end

  test "a plain redirect writes the same bytes to both files", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-plain")
    scope = "page-identity-plain"
    old = "#{url}/id/plain/old"
    new = "#{url}/id/plain/dir/new"

    ReqTestSite.expect_once(site, "GET", "/id/plain/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect_once(site, "GET", "/id/plain/dir/new", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.resp(200, "PLAIN")
    end)

    opts = crawl(old, scope: scope, workers: 1, save_to: root, req_options: req_options)
    await_idle(opts)

    assert File.read!(saved(root, old)) == "PLAIN"
    assert File.read!(saved(root, new)) == "PLAIN"
    assert Snapshot.path(old) != Snapshot.path(new)
  end

  test "a trailing slash redirect writes one file", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-slash")
    scope = "page-identity-slash"
    page = "#{url}/id/slash"
    slashed = page <> "/"

    ReqTestSite.expect_once(site, "GET", "/id/slash", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", slashed)
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect_once(site, "GET", "/id/slash/", fn conn ->
      Plug.Conn.resp(conn, 200, "SLASH")
    end)

    opts = crawl(page, scope: scope, workers: 1, save_to: root, req_options: req_options)
    await_idle(opts)

    assert Snapshot.path(page) == Snapshot.path(slashed)
    assert File.read!(saved(root, page)) == "SLASH"
    assert Store.find_processed({page, scope}).body == "SLASH"
    assert Store.find_processed({slashed, scope}).body == "SLASH"
    assert Store.ops_count(scope) == 1
  end

  defp new_log, do: :ets.new(:page_identity, [:duplicate_bag, :public])

  defp log(table, item), do: :ets.insert(table, {item})

  defp logged(table) do
    Enum.map(:ets.tab2list(table), fn {item} -> item end)
  end

  defp new_count, do: :counters.new(1, [:atomics])

  defp bump(counter), do: :counters.add(counter, 1, 1)

  defp count(counter), do: :counters.get(counter, 1)

  defp crawl(url, opts) do
    opts = Keyword.merge([store: Store], opts)
    {:ok, opts} = Crawler.crawl(url, opts)
    opts
  end

  defp await_idle(opts) do
    wait(fn -> refute Crawler.running?(opts) end)
  end

  defp fetcher(opts) do
    defaults = %{
      depth: 0,
      retries: 2,
      url_filter: UrlFilter,
      modifier: Modifier,
      retrier: Retrier,
      store: Store,
      html_tag: "a"
    }

    defaults
    |> Map.merge(opts)
    |> Fetcher.fetch()
  end

  defp html(site, path, body) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, body)
    end)
  end

  defp text(site, path, body) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      Plug.Conn.resp(conn, 200, body)
    end)
  end

  defp redirect(request, location) do
    {request, Req.Response.new(status: 302, headers: [{"location", location}], body: "")}
  end

  defp html_response(request, body) do
    {request, Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
  end

  defp text_response(request, body) do
    {request,
     Req.Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: body)}
  end

  defp saved(root, url), do: Path.join(root, Snapshot.path(url))

  defp assert_link_opens(root, from_url, to_url) do
    body = File.read!(saved(root, from_url))
    href = Linker.offline_link(from_url, to_url)
    assert body =~ href

    {relative, _fragment} = split_fragment(href)
    opened = Path.expand(relative, Path.dirname(saved(root, from_url)))
    assert File.read!(opened) == File.read!(saved(root, to_url))
  end

  defp split_fragment(href) do
    case String.split(href, "#", parts: 2) do
      [path, fragment] -> {path, "#" <> fragment}
      [path] -> {path, ""}
    end
  end
end
