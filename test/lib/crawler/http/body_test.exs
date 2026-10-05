defmodule Crawler.HTTP.BodyTest do
  use ExUnit.Case, async: true

  alias Crawler.HTTP.Body
  alias Crawler.HTTP.BodyTooLarge
  alias Crawler.HTTP.UnsupportedEncoding

  test "gzip, deflate, and identity bodies decode to the original bytes" do
    html = "<a href=\"/next\">Next</a>"

    assert decode(:zlib.gzip(html), "gzip", 1000) == html
    assert decode(:zlib.gzip(html), "x-gzip", 1000) == html
    assert decode(deflate(html), "deflate", 1000) == html
    assert decode(html, nil, 1000) == html
  end

  test "a body can arrive in chunks" do
    gzip = :zlib.gzip("abcdefghij")
    {head, tail} = String.split_at(gzip, 8)

    assert decode_chunks([head, tail], "gzip", 1000) == "abcdefghij"
  end

  test "a truncated gzip body is rejected instead of returned" do
    gzip = :zlib.gzip("partial-page-body")
    chopped = binary_part(gzip, 0, byte_size(gzip) - 5)

    assert {_request, %UnsupportedEncoding{encoding: "gzip"}} = finish(chopped, "gzip", 1000)
  end

  test "bytes above the cap are discarded, including after decompression" do
    assert {_request, %BodyTooLarge{max_body: 4}} = finish("12345", nil, 4)

    assert {_request, %BodyTooLarge{max_body: 4}} =
             finish(:zlib.gzip(:binary.copy(<<0>>, 20)), "gzip", 4)
  end

  test "decompression stops once the decoded cap is passed" do
    gzip = :zlib.gzip(:binary.copy(<<0>>, 200_000))
    request = request(1_000)
    response = response("gzip")

    assert {:halt, {request, response}} = Body.stream({:data, gzip}, {request, response})
    state = Req.Response.get_private(response, :crawler_body)

    assert state.overflow
    assert state.chunks == []
    assert state.size < 50_000
    assert {_request, %BodyTooLarge{max_body: 1_000}} = Body.finish({request, response})
  end

  test "later chunks stop once the cap is passed" do
    request = request(4)
    response = response(nil)

    assert {:cont, {request, response}} = Body.stream({:data, "ab"}, {request, response})
    assert {:halt, {request, response}} = Body.stream({:data, "cdef"}, {request, response})
    assert {_request, %BodyTooLarge{max_body: 4}} = Body.finish({request, response})
  end

  test "an unsupported encoding is rejected and a preset body is left unchanged" do
    assert {_request, %UnsupportedEncoding{encoding: "br"}} = finish("bytes", "br", 1000)

    request = request(10)
    response = Req.Response.new(status: 200, body: "ok")
    assert {_request, %{body: "ok"}} = Body.finish({request, response})
  end

  defp decode(data, encoding, max) do
    {_request, response} = finish(data, encoding, max)
    response.body
  end

  defp decode_chunks(chunks, encoding, max) do
    request = request(max)
    response = response(encoding)

    {request, response} =
      Enum.reduce(chunks, {request, response}, fn chunk, acc ->
        assert {:cont, acc} = Body.stream({:data, chunk}, acc)
        acc
      end)

    {_request, response} = Body.finish({request, response})
    response.body
  end

  defp finish(data, encoding, max) do
    request = request(max)
    response = response(encoding)

    {request, response} =
      case Body.stream({:data, data}, {request, response}) do
        {:cont, acc} -> acc
        {:halt, acc} -> acc
      end

    Body.finish({request, response})
  end

  defp request(max) do
    [url: "http://example.test/page"]
    |> Req.new()
    |> Req.Request.register_options([:crawler_max_body])
    |> Req.Request.merge_options(crawler_max_body: max)
  end

  defp response(nil), do: Req.Response.new(status: 200)

  defp response(encoding) do
    Req.Response.new(status: 200, headers: [{"content-encoding", encoding}])
  end

  defp deflate(data) do
    zlib = :zlib.open()
    :zlib.deflateInit(zlib)
    compressed = :zlib.deflate(zlib, data, :finish)
    :zlib.deflateEnd(zlib)
    :zlib.close(zlib)
    IO.iodata_to_binary(compressed)
  end
end
