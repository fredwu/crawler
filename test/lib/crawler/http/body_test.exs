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

  test "layered encodings decode from the outside in" do
    html = "<a href=\"/next\">Next</a>"

    assert decode(:zlib.gzip(:zlib.gzip(html)), "gzip, gzip", 1000) == html
    assert decode(:zlib.gzip(:zlib.gzip(html)), ["gzip", "gzip"], 1000) == html
    assert decode(:zlib.gzip(html), "identity, gzip", 1000) == html
    assert decode(deflate(:zlib.gzip(html)), "gzip, deflate", 1000) == html
    assert decode(:zlib.gzip(deflate(html)), ["deflate", "gzip"], 1000) == html
  end

  test "layered decompression stops once the decoded cap is passed" do
    gzip = :zlib.gzip(:zlib.gzip(:binary.copy(<<0>>, 200_000)))
    request = request(1_000)
    response = response("gzip, gzip")

    assert {:halt, {request, response}} = Body.stream({:data, gzip}, {request, response})
    state = Req.Response.get_private(response, :crawler_body)

    assert state.overflow
    assert state.chunks == []
    assert state.size < 50_000
    assert {_request, %BodyTooLarge{max_body: 1_000}} = Body.finish({request, response})
  end

  test "layered overflow closes every inflate stream" do
    gzip = :zlib.gzip(:zlib.gzip(:binary.copy(<<0>>, 200_000)))

    closes =
      :global.trans({:crawler_zlib_close_trace, :lock}, fn ->
        trace_overflow(gzip)
      end)

    assert closes == 2
  end

  test "an encoded body with no bytes is rejected" do
    request = request(1_000)

    assert {_request, %UnsupportedEncoding{encoding: "br"}} =
             Body.finish({request, response("br")})

    assert {_request, %UnsupportedEncoding{encoding: "gzip"}} =
             Body.finish({request, response("gzip")})

    assert {_request, %{body: "ok"}} =
             Body.finish({request, identity_response()})
  end

  test "release closes an open inflate stream and can run again" do
    gzip = :zlib.gzip("page-body")
    chunk = binary_part(gzip, 0, byte_size(gzip) - 8)
    request = request(1_000)
    response = response("gzip")

    assert {:cont, {request, response}} = Body.stream({:data, chunk}, {request, response})
    state = Req.Response.get_private(response, :crawler_body)
    refute state.closed?
    [%{z: zlib}] = state.layers

    assert Body.release({request, response}) == :ok
    assert catch_error(:zlib.safeInflate(zlib, <<>>)) == :not_initialized
    assert Body.release({request, response}) == :ok
  end

  test "an unsupported encoding is rejected and a preset body is left unchanged" do
    assert {_request, %UnsupportedEncoding{encoding: "br"}} = finish("bytes", "br", 1000)

    request = request(10)
    response = Req.Response.new(status: 200, body: "ok")
    assert {_request, %{body: "ok"}} = Body.finish({request, response})
  end

  defp trace_overflow(gzip) do
    :erlang.trace_pattern({:zlib, :close, 1}, true, [])

    try do
      count_overflow(gzip)
    after
      :erlang.trace_pattern({:zlib, :close, 1}, false, [])
    end
  end

  defp count_overflow(gzip) do
    parent = self()

    pid =
      spawn(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, parent}])
        request = request(1_000)
        response = response("gzip, gzip")
        Body.stream({:data, gzip}, {request, response})
        send(parent, :done)
      end)

    assert_receive :done, 5_000
    close_count(pid)
  end

  defp identity_response do
    Req.Response.new(status: 200, body: "ok", headers: [{"content-encoding", "identity"}])
  end

  defp close_count(pid) do
    receive do
      {:trace, ^pid, :call, {:zlib, :close, _args}} -> 1 + close_count(pid)
    after
      200 -> 0
    end
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

  defp response(encodings) do
    headers =
      encodings
      |> List.wrap()
      |> Enum.map(&{"content-encoding", &1})

    Req.Response.new(status: 200, headers: headers)
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
