defmodule Crawler.RedirectResponseTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store

  import Crawler.RedirectHelpers
  alias Crawler.RedirectHelpers.HostFilter

  test "redirect: false returns the redirect response" do
    scope = "page-identity-no-follow"
    seen = RequestLog.new()

    pages = %{
      "/id/no-js" => "javascript:alert(1)",
      "/id/no-filter" => "http://evil.test/secret"
    }

    adapter = fn request ->
      RequestLog.record(seen, {request.url.host, request.url.path})
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

    assert RequestLog.frequencies(seen) == %{
             {"ex.com", "/id/no-js"} => 1,
             {"ex.com", "/id/no-filter"} => 1
           }
  end

  test "max_redirects: 0 reports too many redirects for a rejected location" do
    scope = "page-identity-cap"
    seen = RequestLog.new()

    pages = %{
      "/id/cap-js" => "javascript:alert(1)",
      "/id/cap-evil" => "http://evil.test/secret"
    }

    adapter = fn request ->
      RequestLog.record(seen, {request.url.host, request.url.path})
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

    assert RequestLog.frequencies(seen) == %{
             {"ex.com", "/id/cap-js"} => 2,
             {"ex.com", "/id/cap-evil"} => 2
           }
  end

  test "a redirect past the hop limit is not a rejected redirect" do
    scope = "page-identity-chain"
    seen = RequestLog.new()
    page = "http://ex.com/id/chain/0"

    adapter = fn request ->
      RequestLog.record(seen, {request.url.host, request.url.path})

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

    assert RequestLog.frequencies(seen) ==
             Map.new(0..5, fn step -> {{"ex.com", "/id/chain/#{step}"}, 1} end)
  end

  test "a blank location is not followed" do
    scope = "page-identity-blank"
    seen = RequestLog.new()

    pages = %{
      "/id/blank-space" => " ",
      "/id/blank-tab" => "\t"
    }

    adapter = fn request ->
      RequestLog.record(seen, {request.url.host, request.url.path})
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

    assert RequestLog.frequencies(seen) == %{
             {"ex.com", "/id/blank-space"} => 1,
             {"ex.com", "/id/blank-tab"} => 1
           }
  end

  test "a padded location is trimmed before the allow check" do
    scope = "page-identity-padded"
    seen = RequestLog.new()
    page = "http://ex.com/id/padded"

    adapter = fn request ->
      RequestLog.record(seen, {request.url.host, request.url.path})

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

    assert RequestLog.entries(seen) == [{"ex.com", "/id/padded"}]
  end

  test "a location with a tab or a break is the absolute page" do
    scope = "page-identity-location-tab"
    seen = RequestLog.new()
    page = "http://ex.com/id/tabby"
    land = "http://ex.com/land"

    adapter = fn request ->
      RequestLog.record(seen, {request.url.host, request.url.path})

      cond do
        request.url.path == "/id/tabby" ->
          redirect(request, "ht\ttp://ex.com/land")

        request.url.path == "/id/break" ->
          redirect(request, "java\nscript:alert(1)")

        request.url.path == "/land" ->
          text_response(request, "LAND")

        true ->
          text_response(request, "LEAK")
      end
    end

    assert %Store.Page{body: "LAND"} =
             fetcher(%{
               url: page,
               scope: scope,
               retries: 2,
               url_filter: HostFilter,
               req_options: [adapter: adapter, retry: false]
             })

    assert Store.find({land, scope}).body == "LAND"

    assert RequestLog.frequencies(seen) == %{
             {"ex.com", "/id/tabby"} => 1,
             {"ex.com", "/land"} => 1
           }

    script = "http://ex.com/id/break"

    assert {:warn, message} =
             fetcher(%{
               url: script,
               scope: scope,
               retries: 2,
               url_filter: HostFilter,
               req_options: [adapter: adapter, retry: false]
             })

    assert message =~ "Redirect rejected"
    refute message =~ "/javascript:"

    assert RequestLog.frequencies(seen) == %{
             {"ex.com", "/id/tabby"} => 1,
             {"ex.com", "/land"} => 1,
             {"ex.com", "/id/break"} => 1
           }
  end
end
