defmodule Crawler.HTTP.BodyDeadlineTest do
  use ExUnit.Case, async: true

  alias Crawler.Deadline
  alias Crawler.HTTP.Body
  alias Crawler.HTTP.BodyTooLarge
  alias Crawler.HTTP.DeadlineExceeded
  alias Crawler.HTTP.Stream

  test "expired streamed and preset bodies stop before processing input" do
    for kind <- [:attempt, :run] do
      request = request(expired(kind))
      response = response()

      assert {:halt, {halted, %DeadlineExceeded{reason: {:deadline, ^kind}}}} =
               Body.stream({:data, [999]}, {request, response})

      assert halted.halted

      assert {halted, %DeadlineExceeded{reason: {:deadline, ^kind}}} =
               Body.finish({request, %{response | body: [999]}})

      assert halted.halted
    end
  end

  test "an expired event closes a decoder held between chunks" do
    request = request(Deadline.after_ms(30_000))
    gzip = :zlib.gzip("a complete page")
    {head, tail} = :erlang.split_binary(gzip, 8)

    assert {:cont, {request, response}} =
             Body.stream({:data, head}, {request, response("gzip")})

    [%{z: zlib}] = state(response).layers
    request = Req.Request.put_option(request, :crawler_deadline, expired(:run))

    assert {:halt, {_request, %DeadlineExceeded{reason: {:deadline, :run}}}} =
             Body.stream({:data, tail}, {request, response})

    assert catch_error(:zlib.safeInflate(zlib, <<>>)) == :not_initialized
  end

  test "decoder drains check their captured deadline and close all layers" do
    request = request(Deadline.after_ms(30_000))
    gzip = :zlib.gzip(:zlib.gzip(:binary.copy(<<0>>, 200_000)))
    {head, tail} = :erlang.split_binary(gzip, 8)

    assert {:cont, {request, response}} =
             Body.stream({:data, head}, {request, response("gzip, gzip")})

    original = state(response)
    [outer, inner] = original.layers
    inner = %{inner | deadline: expired(:attempt)}

    response =
      Req.Response.put_private(response, :crawler_body, %{original | layers: [outer, inner]})

    assert {:halt, {request, response}} = Body.stream({:data, tail}, {request, response})
    assert state(response).closed?
    assert state(response).chunks == []

    assert {_request, %DeadlineExceeded{reason: {:deadline, :attempt}}} =
             Body.finish({request, response})

    for layer <- original.layers do
      assert catch_error(:zlib.safeInflate(layer.z, <<>>)) == :not_initialized
    end
  end

  test "finish releases an expired decoder before flattening output" do
    request = request(Deadline.after_ms(30_000))
    gzip = :zlib.gzip("a complete page")

    assert {:cont, {request, response}} =
             Body.stream({:data, gzip}, {request, response("gzip")})

    [%{z: zlib}] = state(response).layers
    request = Req.Request.put_option(request, :crawler_deadline, expired(:attempt))

    assert {_request, %DeadlineExceeded{reason: {:deadline, :attempt}}} =
             Body.finish({request, response})

    assert catch_error(:zlib.safeInflate(zlib, <<>>)) == :not_initialized
  end

  test "chunks keep one absolute deadline and a recorded body limit stays terminal" do
    deadline = Deadline.after_ms(30_000)
    request = request(deadline, 4)

    assert {:cont, {request, response}} = Body.stream({:data, "ab"}, {request, response()})
    assert state(response).deadline == deadline
    assert {:cont, {request, response}} = Body.stream({:data, "cd"}, {request, response})
    assert state(response).deadline == deadline
    assert {:halt, {request, response}} = Body.stream({:data, "e"}, {request, response})

    request = Req.Request.put_option(request, :crawler_deadline, expired(:attempt))
    assert {_request, %BodyTooLarge{max_body: 4}} = Body.finish({request, response})
  end

  test "the stream refuses expired work before opening a connection" do
    request = request(expired(:run))
    finch_request = Finch.build(:get, "http://127.0.0.1:1/expired")

    assert {halted, %DeadlineExceeded{kind: :run, reason: {:deadline, :run}}} =
             Stream.stream(request, finch_request, :unused_finch, [])

    assert halted.halted
  end

  test "a held wire response checks expiry before the next data callback" do
    start_supervised!({Finch, name: __MODULE__.Finch})
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    gzip = :zlib.gzip("a complete page")
    {head, tail} = :erlang.split_binary(gzip, 8)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5000)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: ",
            Integer.to_string(byte_size(gzip)),
            "\r\nconnection: close\r\n\r\n",
            head
          ])

        receive do
          :continue -> :gen_tcp.send(socket, tail)
        after
          5000 -> :ok
        end

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listen)
      Process.exit(server, :kill)
    end)

    parent = self()

    into = fn event, acc ->
      assert {:cont, {request, response}} = Body.stream(event, acc)
      [%{z: zlib}] = state(response).layers
      send(parent, {:held_decoder, zlib})
      send(server, :continue)
      request = Req.Request.put_option(request, :crawler_deadline, expired(:run))
      {:cont, {request, response}}
    end

    request = %{request(Deadline.after_ms(30_000)) | into: into}
    finch_request = Finch.build(:get, "http://127.0.0.1:#{port}/held")

    assert {_request, %DeadlineExceeded{reason: {:deadline, :run}}} =
             Stream.stream(request, finch_request, __MODULE__.Finch, receive_timeout: 5000)

    assert_receive {:held_decoder, zlib}
    refute_receive {:held_decoder, _other}
    assert catch_error(:zlib.safeInflate(zlib, <<>>)) == :not_initialized
  end

  defp request(deadline, max \\ 1_000_000) do
    [url: "http://example.test/page", into: &Body.stream/2]
    |> Req.new()
    |> Req.Request.register_options([:crawler_max_body, :crawler_deadline])
    |> Req.Request.merge_options(crawler_max_body: max, crawler_deadline: deadline)
  end

  defp response(encoding \\ nil)
  defp response(nil), do: Req.Response.new(status: 200)

  defp response(encoding),
    do: Req.Response.new(status: 200, headers: [{"content-encoding", encoding}])

  defp state(response), do: Req.Response.get_private(response, :crawler_body)
  defp expired(kind), do: %Deadline{at: Deadline.now() - 1, kind: kind}
end
