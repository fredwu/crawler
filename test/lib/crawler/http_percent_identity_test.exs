defmodule Crawler.HTTPPercentIdentityTest do
  use ExUnit.Case, async: true

  alias Crawler.HTTP
  alias Crawler.URL

  test "ASCII spellings with the same request target have one canonical identity" do
    owner = self()

    adapter = fn request ->
      send(owner, {:wire_url, URI.to_string(request.url)})
      {request, Req.Response.new(status: 200, body: "OK")}
    end

    for {raw, escaped} <- [
          {"/a|b", "/a%7cb"},
          {"/a%ZZ", "/a%25ZZ"},
          {"/search?q=`{}|%ZZ", "/search?q=%60%7b%7d%7c%25ZZ"}
        ],
        suffix <- [raw, escaped] do
      uri = "http://example.com" <> suffix
      identity = "http://example.com" <> escaped
      assert URL.canonical(uri) == identity

      assert {:ok, response} = HTTP.get(uri, [], adapter: adapter, retry: false)
      assert_received {:wire_url, ^identity}
      assert Req.Response.get_private(response, :crawler_url) == identity
    end
  end
end
