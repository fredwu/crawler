defmodule Crawler.HTTPOptionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Crawler.HTTP

  setup do
    original = Application.fetch_env(:req, :default_options)

    on_exit(fn ->
      case original do
        {:ok, options} -> Application.put_env(:req, :default_options, options)
        :error -> Application.delete_env(:req, :default_options)
      end
    end)

    :ok
  end

  test "rejects obsolete redirect options inherited from Req global defaults" do
    owner = self()

    adapter = fn request ->
      send(owner, {:requested, URI.to_string(request.url)})

      {request,
       Req.Response.new(status: 302, headers: [{"location", "http://blocked.test/private"}])}
    end

    allow = fn url ->
      send(owner, {:policy, url})
      false
    end

    for follow_redirects <- [true, false] do
      Req.default_options(follow_redirects: follow_redirects)

      assert_raise ArgumentError,
                   ":follow_redirects is not supported; use :redirect instead",
                   fn ->
                     HTTP.get(
                       "http://example.com/start",
                       [],
                       [adapter: adapter, redirect: false],
                       allow
                     )
                   end
    end

    refute_received {:requested, _}
    refute_received {:policy, _}
  end

  test "direct HTTP calls follow allowed credentialed redirects without logging credentials" do
    owner = self()
    location = "http://landing-user:landing-secret@example.com/landing"

    adapter = fn request ->
      send(owner, {:requested, URI.to_string(request.url), request.options[:redirect_log_level]})

      response =
        case request.url.path do
          "/start" -> Req.Response.new(status: 302, headers: [{"location", location}])
          "/landing" -> Req.Response.new(status: 200, body: "OK")
        end

      {request, response}
    end

    allow = fn url ->
      send(owner, {:allowed, url})
      true
    end

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, response} =
                 HTTP.get("http://example.com/start", [], [adapter: adapter, retry: false], allow)

        assert response.body == "OK"
        assert Req.Response.get_private(response, :crawler_url) == location
      end)

    assert_received {:requested, "http://example.com/start", false}
    assert_received {:requested, ^location, false}
    assert_received {:allowed, ^location}
    refute log =~ "landing-user"
    refute log =~ "landing-secret"
    refute log =~ "redirecting"
  end

  test "direct HTTP calls preserve an explicit redirect logging level" do
    owner = self()

    adapter = fn request ->
      send(owner, {:logging_level, request.options[:redirect_log_level]})

      response =
        case request.url.path do
          "/start" -> Req.Response.new(status: 302, headers: [{"location", "/landing"}])
          "/landing" -> Req.Response.new(status: 200, body: "OK")
        end

      {request, response}
    end

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %Req.Response{body: "OK"}} =
                 HTTP.get("http://example.com/start", [],
                   adapter: adapter,
                   retry: false,
                   redirect_log_level: :info
                 )
      end)

    assert_received {:logging_level, :info}
    assert_received {:logging_level, :info}
    assert log =~ "redirecting to http://example.com/landing"
  end
end
