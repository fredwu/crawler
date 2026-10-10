defmodule Crawler.HTTP.StreamHeadersTest do
  use ExUnit.Case, async: true

  alias Crawler.HTTP
  alias Crawler.HTTP.Body
  alias Crawler.Store

  # Plug keeps repeated headers. These requests stream through Finch, which is
  # the path that used to keep only the last Set-Cookie and Link field.
  test "a streamed response keeps every set-cookie and link field" do
    parent = self()

    port =
      serve(fn request, socket ->
        send(parent, {:served, request_path(request), header_map(request)})

        reply(
          socket,
          200,
          "OK",
          [
            {"content-type", "text/plain"},
            {"set-cookie", "session=abc; Path=/"},
            {"set-cookie", "csrf=xyz; Path=/"},
            {"link", "</app.css>; rel=\"stylesheet\""},
            {"link", "</extra.css>; rel=\"stylesheet\""}
          ],
          "ok"
        )
      end)

    scope = unique("stream-headers")
    url = "http://127.0.0.1:#{port}/both"

    assert {:ok, response} = get(url, scope)
    assert response.body == "ok"
    assert Req.Response.get_private(response, :crawler_body)

    assert Req.Response.get_header(response, "set-cookie") == [
             "session=abc; Path=/",
             "csrf=xyz; Path=/"
           ]

    assert Req.Response.get_header(response, "link") == [
             "</app.css>; rel=\"stylesheet\"",
             "</extra.css>; rel=\"stylesheet\""
           ]

    assert pairs(Store.cookie_header(scope, url)) == %{"session" => "abc", "csrf" => "xyz"}
  end

  test "a streamed same-host redirect sends every set-cookie on the next request" do
    parent = self()

    port =
      serve(fn request, socket ->
        send(parent, {:served, request_path(request), header_map(request)})

        case request_path(request) do
          "/start" ->
            reply(
              socket,
              302,
              "Found",
              [
                {"location", "/next"},
                {"set-cookie", "session=abc; Path=/"},
                {"set-cookie", "csrf=xyz; Path=/"}
              ],
              ""
            )

          "/next" ->
            reply(socket, 200, "OK", [{"content-type", "text/plain"}], "land")
        end
      end)

    scope = unique("stream-redirect")
    url = "http://127.0.0.1:#{port}/start"

    assert {:ok, response} = get(url, scope)
    assert response.status == 200
    assert response.body == "land"
    assert Req.Response.get_private(response, :crawler_body)

    assert_receive {:served, "/start", _headers}
    assert_receive {:served, "/next", headers}
    assert headers["cookie"] =~ "session=abc"
    assert headers["cookie"] =~ "csrf=xyz"
    assert pairs(Store.cookie_header(scope, url)) == %{"session" => "abc", "csrf" => "xyz"}
  end

  test "a redirect and a broken transfer close the inflate stream" do
    page = :zlib.gzip("page")
    redirect = serve(fn request, socket -> redirect_hop(request, socket, page) end)
    broken = serve(fn _request, socket -> reply_incomplete(socket, page) end)

    exhausted =
      serve(fn _request, socket -> reply(socket, 302, "Found", gzip_headers(), page) end)

    assert closes(:redirect, fn ->
             get("http://127.0.0.1:#{redirect}/start", unique("gzip-redirect"))
           end) == 1

    assert closes(:error, fn ->
             get("http://127.0.0.1:#{broken}/short", unique("gzip-broken"))
           end) == 1

    assert closes(:exhausted, fn ->
             get("http://127.0.0.1:#{exhausted}/stop", unique("gzip-exhausted"), max_redirects: 0)
           end) == 1
  end

  test "a redirect that is not followed still decodes its body" do
    page = "<p>stay</p>"
    gzip = :zlib.gzip(page)

    port =
      serve(fn _request, socket ->
        reply(socket, 302, "Found", gzip_headers(), gzip)
      end)

    assert {:ok, response} =
             HTTP.get(
               "http://127.0.0.1:#{port}/stay",
               [],
               into: &Body.stream/2,
               decode_body: false,
               retry: false,
               redirect: false,
               receive_timeout: 5_000
             )

    assert response.status == 302
    assert response.body == page
  end

  defp get(url, scope, opts \\ []) do
    HTTP.get(
      url,
      [],
      Keyword.merge(
        [
          into: &Body.stream/2,
          crawler_scope: scope,
          decode_body: false,
          retry: false,
          redirect: true,
          receive_timeout: 5_000
        ],
        opts
      )
    )
  end

  defp closes(kind, fun) do
    :global.trans({:crawler_zlib_close_trace, :lock}, fn ->
      traced_closes(kind, fun)
    end)
  end

  defp traced_closes(kind, fun) do
    :erlang.trace_pattern({:zlib, :close, 1}, true, [])

    try do
      run_traced(kind, fun)
    after
      :erlang.trace_pattern({:zlib, :close, 1}, false, [])
    end
  end

  defp run_traced(kind, fun) do
    parent = self()

    pid =
      spawn(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, parent}])
        send(parent, {:done, fun.()})
      end)

    assert_receive {:done, result}, 10_000
    assert_kind(kind, result)
    close_count(pid)
  end

  defp assert_kind(:redirect, {:ok, response}) do
    assert response.status == 200
    assert response.body == "land"
  end

  defp assert_kind(:error, {:error, _error}), do: :ok

  defp assert_kind(:exhausted, {:error, %Req.TooManyRedirectsError{}}), do: :ok

  defp redirect_hop(request, socket, page) do
    case request_path(request) do
      "/start" -> reply(socket, 302, "Found", gzip_headers(), page)
      "/next" -> reply(socket, 200, "OK", [{"content-type", "text/plain"}], "land")
    end
  end

  defp gzip_headers do
    [{"location", "/next"}, {"content-type", "text/html"}, {"content-encoding", "gzip"}]
  end

  defp reply_incomplete(socket, body) do
    declared = byte_size(body) + 64

    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "content-length: ",
      Integer.to_string(declared),
      "\r\n",
      "content-encoding: gzip\r\n",
      "content-type: text/plain\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ])

    :gen_tcp.close(socket)
  end

  defp close_count(pid) do
    receive do
      {:trace, ^pid, :call, {:zlib, :close, _args}} -> 1 + close_count(pid)
    after
      200 -> 0
    end
  end

  defp serve(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn -> accept_loop(listen, handler, parent) end)

    on_exit(fn -> :gen_tcp.close(listen) end)
    port
  end

  defp accept_loop(listen, handler, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve_one(socket, handler, parent)
        accept_loop(listen, handler, parent)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_one(socket, handler, parent) do
    case read_request(socket, <<>>) do
      {:ok, request} ->
        handler.(request, socket)

      {:error, reason} ->
        send(parent, {:server_error, reason})
        :gen_tcp.close(socket)
    end
  end

  defp read_request(_socket, acc) when byte_size(acc) > 65_536, do: {:error, :too_large}

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_request(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp reply(socket, status, reason, headers, body) do
    headers = [
      {"content-length", Integer.to_string(byte_size(body))},
      {"connection", "close"} | headers
    ]

    lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason,
      "\r\n",
      lines,
      "\r\n",
      body
    ])

    :gen_tcp.close(socket)
  end

  defp request_path(request) do
    [line | _] = String.split(request, "\r\n", parts: 2)
    [_, target | _] = String.split(line, " ")
    target |> String.split("?", parts: 2) |> hd()
  end

  defp header_map(request) do
    request
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.reduce(%{}, &put_header/2)
  end

  defp put_header(line, acc) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        Map.update(acc, String.downcase(name), String.trim(value), &join_header(&1, value))

      _other ->
        acc
    end
  end

  defp join_header(previous, value), do: previous <> ", " <> String.trim(value)

  defp pairs(nil), do: %{}

  defp pairs(header) do
    Map.new(String.split(header, ";"), fn piece ->
      [name, value] = piece |> String.trim() |> String.split("=", parts: 2)
      {name, value}
    end)
  end

  defp unique(name), do: "#{name}-#{System.unique_integer([:positive])}"
end
