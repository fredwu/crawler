defmodule Crawler.HTTPPercentIdentityTest do
  use ExUnit.Case, async: true

  alias Crawler.HTTP
  alias Crawler.URL

  test "browser path and query spellings keep distinct request targets" do
    owner = self()

    adapter = fn request ->
      send(owner, {:wire_url, URI.to_string(request.url)})
      {request, Req.Response.new(status: 200, body: "OK")}
    end

    pairs = [
      {"/a|b", "http://example.com/a|b"},
      {"/a%7Cb", "http://example.com/a%7cb"},
      {"/a%ZZ", "http://example.com/a%ZZ"},
      {"/a%25ZZ", "http://example.com/a%25ZZ"},
      {"/search?q=`{}|%ZZ", "http://example.com/search?q=`{}|%ZZ"},
      {"/search?q=%60%7B%7D%7C%5C%5E", "http://example.com/search?q=%60%7b%7d%7c%5c%5e"},
      {"/foo%2ehtml", "http://example.com/foo%2ehtml"},
      {"http://example.com./a", "http://example.com./a"},
      {"http://user@example.com@evil.com/secret", "http://user%40example.com@evil.com/secret"}
    ]

    for {suffix, identity} <- pairs do
      uri =
        if String.starts_with?(suffix, "http"), do: suffix, else: "http://example.com" <> suffix

      assert URL.canonical(uri) == identity

      assert {:ok, response} = HTTP.get(uri, [], adapter: adapter, retry: false)
      assert_received {:wire_url, ^identity}
      assert Req.Response.get_private(response, :crawler_url) == identity
    end

    refute URL.canonical("http://example.com/a|b") == URL.canonical("http://example.com/a%7cb")
    refute URL.canonical("http://example.com/a%ZZ") == URL.canonical("http://example.com/a%25ZZ")
  end

  test "a rejected authority produces no request" do
    adapter = fn request ->
      send(self(), {:requested, URI.to_string(request.url)})
      {request, Req.Response.new(status: 200, body: "OK")}
    end

    for url <- [
          "http://user:a#b@example.com/a",
          "http://user:a/b@example.com/a"
        ] do
      assert {:error, %HTTP.InvalidURL{}} = HTTP.get(url, [], adapter: adapter, retry: false)
    end

    refute_received {:requested, _}
  end
end
