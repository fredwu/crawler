defmodule Crawler.Fetcher.RequesterTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher.Modifier
  alias Crawler.Fetcher.Requester

  doctest Requester

  defmodule HeaderModifier do
    @behaviour Modifier.Spec

    def headers(_opts), do: [{"X-Crawler-Test", "modifier"}]
    def opts(_opts), do: [params: [from_modifier: "yes"]]
  end

  defmodule PrecedenceModifier do
    @behaviour Modifier.Spec

    def headers(_opts) do
      [
        {"USER-AGENT", "Modifier Agent"},
        {"X-Order", "modifier header"},
        {"X-Modifier", "retained"}
      ]
    end

    def opts(_opts) do
      [
        headers: %{"x-ORDER" => ["modifier option"], "X-Modifier-Option" => "retained"},
        max_redirects: 3
      ]
    end
  end

  defmodule RejectForeignHost do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(url, opts) do
      send(opts[:test_pid], {:policy, url})
      {:ok, URI.parse(url).host == "example.com"}
    end
  end

  test "builds Req requests with crawler defaults, headers, and modifier options" do
    test_pid = self()

    adapter = fn request ->
      send(test_pid, {:request, request})

      {request, Req.Response.new(status: 200, body: "{\"ok\":true}")}
    end

    assert {:ok, %Req.Response{status: 200, body: "{\"ok\":true}"}} =
             Requester.make(%{
               url: "http://example.com/path",
               user_agent: "Crawler Test",
               timeout: 123,
               modifier: HeaderModifier,
               req_options: [adapter: adapter]
             })

    assert_receive {:request, request}

    assert request.method == :get
    assert URI.to_string(request.url) == "http://example.com/path?from_modifier=yes"
    assert Req.Request.get_header(request, "user-agent") == ["Crawler Test"]
    assert Req.Request.get_header(request, "x-crawler-test") == ["modifier"]
    assert request.options[:redirect] == true
    assert request.options[:max_redirects] == 5
    assert request.options[:retry] == false
    assert request.options[:decode_body] == false
    assert request.options[:receive_timeout] == 123
  end

  test "preserves infinity timeout for long-lived paused crawls" do
    test_pid = self()

    adapter = fn request ->
      send(test_pid, {:request, request})

      {request, Req.Response.new(status: 200, body: "ok")}
    end

    assert {:ok, %Req.Response{status: 200}} =
             Requester.make(%{
               url: "http://example.com/slow",
               user_agent: "Crawler Test",
               timeout: :infinity,
               modifier: Modifier,
               req_options: [adapter: adapter]
             })

    assert_receive {:request, request}
    assert request.options[:receive_timeout] == :infinity
  end

  test "merges headers case-insensitively with explicit headers last" do
    owner = self()

    adapter = fn request ->
      send(owner, {:request, request})
      {request, Req.Response.new(status: 200, body: "ok")}
    end

    for headers <- [
          [{"x-order", "explicit"}, {"X-Explicit", "new"}, {"User-Agent", "Caller Agent"}],
          %{"X-ORDER" => ["explicit"], "x-explicit" => "new", "user-agent" => "Caller Agent"}
        ] do
      assert {:ok, _response} =
               Requester.make(%{
                 url: "http://example.com/headers",
                 user_agent: "Default Agent",
                 modifier: PrecedenceModifier,
                 req_options: [
                   adapter: adapter,
                   headers: headers,
                   auth: {:bearer, "caller-token"},
                   max_redirects: 2
                 ]
               })

      assert_received {:request, request}
      assert request.headers["x-order"] == ["explicit"]
      assert request.headers["x-explicit"] == ["new"]
      assert request.headers["user-agent"] == ["Caller Agent"]
      assert request.headers["x-modifier"] == ["retained"]
      assert request.headers["x-modifier-option"] == ["retained"]
      assert request.headers["authorization"] == ["Bearer caller-token"]
      assert request.options[:max_redirects] == 2
      refute Map.has_key?(request.headers, "X-Order")
    end
  end

  test "modifier options override callback headers and retain unrelated headers" do
    owner = self()

    adapter = fn request ->
      send(owner, {:headers, request.headers})
      {request, Req.Response.new(status: 200, body: "ok")}
    end

    assert {:ok, _response} =
             Requester.make(%{
               url: "http://example.com/headers",
               user_agent: "Default Agent",
               modifier: PrecedenceModifier,
               req_options: [adapter: adapter]
             })

    assert_received {:headers, headers}
    assert headers["x-order"] == ["modifier option"]
    assert headers["user-agent"] == ["Modifier Agent"]
    assert headers["x-modifier"] == ["retained"]
    assert headers["x-modifier-option"] == ["retained"]
  end

  test "rejects obsolete redirect options before any request or policy evaluation" do
    owner = self()

    adapter = fn request ->
      send(owner, {:requested, URI.to_string(request.url)})

      {request,
       Req.Response.new(status: 302, headers: [{"location", "http://blocked.test/private"}])}
    end

    for follow_redirects <- [true, false] do
      assert_raise ArgumentError,
                   ":follow_redirects is not supported; use :redirect instead",
                   fn ->
                     Requester.make(%{
                       url: "http://example.com/start",
                       user_agent: "Crawler Test",
                       modifier: Modifier,
                       url_filter: RejectForeignHost,
                       test_pid: owner,
                       req_options: [
                         adapter: adapter,
                         redirect: false,
                         follow_redirects: follow_redirects
                       ]
                     })
                   end
    end

    refute_received {:requested, _}
    refute_received {:policy, _}
  end

  test "supported redirect settings retain policy enforcement" do
    owner = self()

    adapter = fn request ->
      send(owner, {:requested, URI.to_string(request.url)})

      {request,
       Req.Response.new(status: 302, headers: [{"location", "http://blocked.test/private"}])}
    end

    opts = %{
      url: "http://example.com/start",
      user_agent: "Crawler Test",
      modifier: Modifier,
      url_filter: RejectForeignHost,
      test_pid: owner
    }

    assert {:ok, %Req.Response{status: 302}} =
             Requester.make(Map.put(opts, :req_options, adapter: adapter, redirect: false))

    assert_received {:requested, "http://example.com/start"}
    refute_received {:policy, _}

    assert {:error, %Crawler.HTTP.RedirectRejected{url: "http://blocked.test/private"}} =
             Requester.make(Map.put(opts, :req_options, adapter: adapter, redirect: true))

    assert_received {:requested, "http://example.com/start"}
    assert_received {:policy, "http://blocked.test/private"}
    refute_received {:requested, _}
  end

  test "keeps JSON-looking response bodies as binaries" do
    adapter = fn request ->
      response =
        Req.Response.new(
          status: 200,
          headers: %{"content-type" => ["application/json"]},
          body: ~s({"ok":true})
        )

      {request, response}
    end

    assert {:ok, %Req.Response{body: ~s({"ok":true})}} =
             Requester.make(%{
               url: "http://example.com/json",
               user_agent: "Crawler Test",
               timeout: 100,
               modifier: Modifier,
               req_options: [adapter: adapter]
             })
  end

  test "does not use Req's built-in retry for transient HTTP responses" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    adapter = fn request ->
      Agent.update(counter, &(&1 + 1))

      {request, Req.Response.new(status: 500, body: "server error")}
    end

    assert {:ok, %Req.Response{status: 500}} =
             Requester.make(%{
               url: "http://example.com/transient",
               user_agent: "Crawler Test",
               timeout: 100,
               modifier: Modifier,
               req_options: [adapter: adapter]
             })

    assert Agent.get(counter, & &1) == 1
  end
end
