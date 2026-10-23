defmodule Crawler.HTTP.BodyEncodingLimitsTest do
  use ExUnit.Case, async: true

  alias Crawler.HTTP.Body
  alias Crawler.HTTP.BodyLimitExceeded
  alias Crawler.HTTP.UnsupportedEncoding

  test "eight listed encoding layers decode and release all eight resources" do
    body = "a complete page"
    gzip = Enum.reduce(1..8, body, fn _index, bytes -> :zlib.gzip(bytes) end)
    coding = Enum.join(List.duplicate("gzip", 8), ", ")

    {{_request, %{body: ^body}}, calls} = trace_resources(fn -> finish(gzip, [coding]) end)
    assert calls == %{open: 8, close: 8}
  end

  test "a ninth coding in one or repeated fields is rejected before decoder allocation" do
    codings = List.duplicate("gzip", 9)

    for headers <- [codings, [Enum.join(codings, ", ")]] do
      {{_request, error}, calls} = trace_resources(fn -> finish("", headers) end)

      assert %BodyLimitExceeded{
               key: :content_encoding_layers,
               limit: 8,
               reason: {:limit, :content_encoding_layers}
             } = error

      assert calls == %{open: 0, close: 0}
      refute Exception.message(error) =~ "gzip"
    end
  end

  test "the combined header byte cap is inclusive and checked before tokenization" do
    at_limit = "identity" <> String.duplicate(" ", 8192 - byte_size("identity"))

    assert {_request, %{body: "ok"}} = finish("ok", [at_limit])

    {{_request, error}, calls} = trace_resources(fn -> finish("", [at_limit <> " "]) end)

    assert %BodyLimitExceeded{
             key: :content_encoding_bytes,
             limit: 8192,
             reason: {:limit, :content_encoding_bytes}
           } = error

    assert calls == %{open: 0, close: 0}
    assert byte_size(Exception.message(error)) < 100
  end

  test "repeated fields include their comma separators in the aggregate byte budget" do
    whitespace = String.duplicate(" ", 8192 - byte_size("identity") - 1)
    assert {_request, %{body: "ok"}} = finish("ok", ["identity", whitespace])

    assert {_request, %BodyLimitExceeded{reason: {:limit, :content_encoding_bytes}}} =
             finish("", ["identity", whitespace <> " "])

    assert {_request, %{body: "ok"}} = finish("ok", List.duplicate("", 8193))

    assert {_request, %BodyLimitExceeded{reason: {:limit, :content_encoding_bytes}}} =
             finish("", List.duplicate("", 8194))
  end

  test "empty and identity codings do not allocate or consume decoder layers" do
    coding = Enum.join(List.duplicate(" identity, ,", 100), ",")
    {{_request, %{body: "ok"}}, calls} = trace_resources(fn -> finish("ok", [coding]) end)
    assert calls == %{open: 0, close: 0}

    body = "a complete page"
    gzip = Enum.reduce(1..8, body, fn _index, bytes -> :zlib.gzip(bytes) end)
    coding = Enum.join(List.duplicate("identity, gzip, ,", 8), ",")
    assert {_request, %{body: ^body}} = finish(gzip, [coding])
  end

  test "streamed rejection allocates no decoders and allowed malformed data releases them" do
    {{_request, %BodyLimitExceeded{reason: {:limit, :content_encoding_layers}}}, calls} =
      trace_resources(fn ->
        request = request()
        response = response(List.duplicate("gzip", 9))
        assert {:halt, acc} = Body.stream({:data, "invalid"}, {request, response})
        Body.finish(acc)
      end)

    assert calls == %{open: 0, close: 0}

    {{_request, %UnsupportedEncoding{encoding: "gzip"}}, calls} =
      trace_resources(fn -> finish("invalid gzip", List.duplicate("gzip", 8)) end)

    assert calls == %{open: 8, close: 8}
  end

  defp trace_resources(fun) do
    :global.trans({:crawler_zlib_close_trace, self()}, fn ->
      :erlang.trace_pattern({:zlib, :open, 0}, true, [])
      :erlang.trace_pattern({:zlib, :close, 1}, true, [])

      try do
        run_traced(fun)
      after
        :erlang.trace_pattern({:zlib, :open, 0}, false, [])
        :erlang.trace_pattern({:zlib, :close, 1}, false, [])
      end
    end)
  end

  defp run_traced(fun) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, parent}])
        send(parent, {:result, self(), fun.()})

        receive do
          :finish -> :ok
        end
      end)

    try do
      assert_receive {:result, ^pid, result}, 5000
      barrier = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^barrier}, 5000
      send(pid, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5000
      {result, resource_calls(pid, %{open: 0, close: 0})}
    after
      Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp resource_calls(pid, counts) do
    receive do
      {:trace, ^pid, :call, {:zlib, name, _args}} ->
        resource_calls(pid, Map.update!(counts, name, &(&1 + 1)))
    after
      0 -> counts
    end
  end

  defp finish(body, headers) do
    Body.finish({request(), %{response(headers) | body: body}})
  end

  defp request do
    [url: "http://example.test/encodings"]
    |> Req.new()
    |> Req.Request.register_options([:crawler_max_body])
    |> Req.Request.merge_options(crawler_max_body: 1000)
  end

  defp response(headers) do
    Req.Response.new(status: 200, headers: Enum.map(headers, &{"content-encoding", &1}))
  end
end
