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
