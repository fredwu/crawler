defmodule Crawler.HTTP.BodyAdapterTest do
  use ExUnit.Case, async: true

  alias Crawler.HTTP
  alias Crawler.HTTP.Body
  alias Crawler.HTTP.BodyTooLarge
  alias Crawler.HTTP.UnsupportedEncoding

  test "a preset adapter cannot return an oversized identity body" do
    for body <- ["12345", ["12", [~c"345"]]] do
      assert {:error, %BodyTooLarge{max_body: 4}} = get(body, [], 4)
    end
  end

  test "a preset adapter decodes binary and iodata bodies within the cap" do
    gzip = :zlib.gzip("1234")

    for body <- [gzip, [binary_part(gzip, 0, 8), binary_part(gzip, 8, byte_size(gzip) - 8)]] do
      assert {:ok, %{body: "1234"}} = get(body, [{"content-encoding", "gzip"}], 4)
    end
  end

  test "a preset adapter cannot return an oversized decoded body" do
    gzip = :zlib.gzip(:binary.copy(<<0>>, 200_000))

    assert {:error, %BodyTooLarge{max_body: 1000}} =
             get([gzip], [{"content-encoding", "gzip"}], 1000)
  end

  test "a preset adapter cannot return incomplete compressed output" do
    gzip = :zlib.gzip("a complete page")
    truncated = binary_part(gzip, 0, byte_size(gzip) - 5)

    assert {:error, %UnsupportedEncoding{encoding: "gzip"}} =
             get(truncated, [{"content-encoding", "gzip"}], 1000)
  end

  defp get(body, headers, max) do
    adapter = fn request ->
      {request, Req.Response.new(status: 200, body: body, headers: headers)}
    end

    HTTP.get("http://example.test/preset", [],
      adapter: adapter,
      into: &Body.stream/2,
      crawler_max_body: max,
      decode_body: false,
      retry: false
    )
  end
end
