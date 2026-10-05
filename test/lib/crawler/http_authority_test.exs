defmodule Crawler.HTTPAuthorityTest do
  use ExUnit.Case, async: true

  alias Crawler.HTTP

  test "invalid root authorities never reach the request adapter" do
    owner = self()

    adapter = fn request ->
      send(owner, {:requested, request.url})
      {request, Req.Response.new(status: 200)}
    end

    for url <- [
          "http://host:bad/path",
          "http://host:65536/path",
          "http://[bad]/path",
          "http:///path"
        ] do
      assert {:error, %HTTP.InvalidURL{url: ^url}} =
               HTTP.get(url, [], adapter: adapter, retry: false)
    end

    refute_received {:requested, _url}
  end

  test "invalid redirect authorities never reach the adapter or allow callback" do
    owner = self()
    root = "http://example.com/start"

    for location <- [
          "http://example.com:bad/target",
          "//example.com:bad/target",
          "http://example.com:65536/target",
          "http://[bad]/target",
          "http://[::1]suffix/target",
          "http:///target",
          "http://:80/target"
        ] do
      adapter = fn request ->
        send(owner, {:requested, URI.to_string(request.url)})
        {request, Req.Response.new(status: 302, headers: [{"location", location}])}
      end

      allow = fn target ->
        send(owner, {:allowed, target})
        true
      end

      assert {:error, %HTTP.RedirectRejected{url: ^location}} =
               HTTP.get(root, [], [adapter: adapter, retry: false], allow)

      assert_received {:requested, ^root}
      refute_received {:requested, _target}
      refute_received {:allowed, _target}
    end
  end

  test "valid encoded redirect hosts are normalized before filtering and requesting" do
    owner = self()
    root = "http://example.com/start"
    target = "http://foo.com/target"

    adapter = fn request ->
      send(owner, {:requested, URI.to_string(request.url)})

      if request.url.path == "/start" do
        {request,
         Req.Response.new(status: 302, headers: [{"location", "//%EF%BD%86oo.com/target"}])}
      else
        {request, Req.Response.new(status: 200, body: "TARGET")}
      end
    end

    allow = fn url ->
      send(owner, {:allowed, url})
      url == target
    end

    assert {:ok, %Req.Response{body: "TARGET"}} =
             HTTP.get(root, [], [adapter: adapter, retry: false], allow)

    assert_received {:requested, ^root}
    assert_received {:allowed, ^target}
    assert_received {:requested, ^target}
    refute_received {:requested, _url}
  end
end
