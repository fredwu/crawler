defmodule Crawler.HTTPTransportTest do
  use ExUnit.Case, async: true

  alias Crawler.HTTP

  test "the Finch callback receives the correct empty query target and logical URI" do
    owner = self()

    callback = fn request, finch, name, options ->
      send(
        owner,
        {:target, URI.to_string(request.url), Finch.Request.request_path(finch), name, options}
      )

      {:ok, bytes} =
        Mint.HTTP1.Request.encode(
          finch.method,
          Finch.Request.request_path(finch),
          finch.headers,
          finch.body
        )

      send(owner, {:bytes, IO.iodata_to_binary(bytes)})
      {request, Req.Response.new(status: 200, body: "OK")}
    end

    for adapter <- [&Req.Steps.run_finch/1, {Req.Steps, :run_finch, []}],
        {suffix, target} <- [{"/search?", "/search?"}, {"/café?", "/caf%c3%a9?"}] do
      uri = "http://example.com" <> suffix

      assert {:ok, response} =
               HTTP.get(uri, [], adapter: adapter, finch_request: callback, retry: false)

      assert_received {:target, ^uri, ^target, Req.Finch, options}
      assert is_list(options)
      assert_received {:bytes, bytes}
      assert String.starts_with?(bytes, "GET #{target} HTTP/1.1\r\n")
      assert Req.Response.get_private(response, :crawler_url) == uri
    end
  end

  test "default HTTP transport sends ASCII targets with an empty query marker intact" do
    for {suffix, target} <- [
          {"/search", "/search"},
          {"/search?", "/search?"},
          {"/café?q=é", "/caf%c3%a9?q=%c3%a9"},
          {"/caf%C3%A9?q=%C3%A9", "/caf%c3%a9?q=%c3%a9"},
          {"/a%2Fb?q=%26", "/a%2fb?q=%26"},
          {"/café?", "/caf%c3%a9?"}
        ] do
      {url, request_line} = request_once(suffix)
      assert request_line == "GET #{target} HTTP/1.1"
      assert url =~ suffix
    end
  end

  test "transport escaping does not change the final stored URL identity" do
    uri = "http://example.com/café?q=`{}|%ZZ"
    owner = self()

    adapter = fn request ->
      send(owner, {:wire_uri, URI.to_string(request.url)})
      {request, Req.Response.new(status: 200, body: "OK")}
    end

    assert {:ok, response} = HTTP.get(uri, [], adapter: adapter, retry: false)
    assert_received {:wire_uri, "http://example.com/caf%c3%a9?q=%60%7b%7d%7c%25ZZ"}

    assert Req.Response.get_private(response, :crawler_url) ==
             "http://example.com/café?q=%60%7b%7d%7c%25ZZ"
  end

  test "stream callbacks retain the empty query URI" do
    owner = self()

    into = fn {:data, data}, {request, response} ->
      send(owner, {:streamed, URI.to_string(request.url), data})
      {:cont, {request, %{response | body: response.body <> data}}}
    end

    {_url, request_line} = request_once("/stream?", into: into)
    assert request_line == "GET /stream? HTTP/1.1"
    assert_received {:streamed, uri, "OK"}
    assert String.ends_with?(uri, "/stream?")
  end

  test "custom adapters encode each redirect and retain the final logical identity" do
    owner = self()

    adapter = fn request ->
      send(owner, {:adapter, request.url, request.adapter, request.private})

      response =
        case URI.to_string(request.url) do
          "http://example.com/start?" -> redirect("/dir/café?")
          "http://example.com/dir/caf%c3%a9?" -> redirect("child?q=é")
          "http://example.com/dir/child?q=%c3%a9" -> Req.Response.new(status: 200, body: "OK")
        end

      {request, response}
    end

    assert {:ok, response} =
             HTTP.get("http://example.com/start?", [],
               adapter: adapter,
               retry: false,
               redirect_log_level: false
             )

    assert Req.Response.get_private(response, :crawler_url) ==
             "http://example.com/dir/child?q=é"

    for expected <- ["/start?", "/dir/caf%c3%a9?", "/dir/child?q=%c3%a9"] do
      assert_received {:adapter, uri, installed, private}
      assert URI.to_string(uri) == "http://example.com#{expected}"
      assert installed == (&Crawler.HTTP.Transport.run/1)
      assert private.crawler_transport_adapter == adapter
    end

    refute_received {:adapter, _, _, _}
  end

  test "Finch callbacks see each logical hop while request targets are ASCII" do
    owner = self()

    callback = fn request, finch, _name, _options ->
      send(owner, {:hop, URI.to_string(request.url), Finch.Request.request_path(finch)})

      response =
        if request.url.path == "/start",
          do: redirect("/café?"),
          else: Req.Response.new(status: 200, body: "OK")

      {request, response}
    end

    assert {:ok, response} =
             HTTP.get("http://example.com/start?", [],
               finch_request: callback,
               retry: false,
               redirect_log_level: false
             )

    assert_received {:hop, "http://example.com/start?", "/start?"}
    assert_received {:hop, "http://example.com/café?", "/caf%c3%a9?"}
    assert Req.Response.get_private(response, :crawler_url) == "http://example.com/café?"
    refute_received {:hop, _, _}
  end

  test "default transport preserves encoded and bare-query targets across relative redirects" do
    {url, response, lines} =
      request_sequence("/start?", [redirect("/dir/café?"), redirect("child?q=é"), :ok])

    assert lines == [
             "GET /start? HTTP/1.1",
             "GET /dir/caf%c3%a9? HTTP/1.1",
             "GET /dir/child?q=%c3%a9 HTTP/1.1"
           ]

    assert Req.Response.get_private(response, :crawler_url) ==
             URI.to_string(%{URI.parse(url) | path: "/dir/child", query: "q=é"})
  end

  defp redirect(location), do: Req.Response.new(status: 302, headers: [{"location", location}])

  defp request_once(suffix, options \\ []) do
    {url, _response, [line]} = request_sequence(suffix, [:ok], options)
    {url, line}
  end

  defp request_sequence(suffix, responses, options \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_address, port}} = :inet.sockname(listener)
    owner = self()

    server =
      start_supervised!(
        {Task,
         fn ->
           for response <- responses do
             {:ok, socket} = :gen_tcp.accept(listener, 2_000)

             try do
               bytes = request_headers(socket, "")
               send(owner, {:request_line, hd(String.split(bytes, "\r\n"))})
               :ok = :gen_tcp.send(socket, response_bytes(response))
             after
               :gen_tcp.close(socket)
             end
           end
         end},
        id: make_ref()
      )

    monitor = Process.monitor(server)
    url = "http://127.0.0.1:#{port}" <> suffix

    assert {:ok, %Req.Response{body: "OK"} = response} =
             HTTP.get(
               url,
               [],
               Keyword.merge(
                 [retry: false, receive_timeout: 2_000, redirect_log_level: false],
                 options
               )
             )

    lines =
      for _response <- responses do
        assert_receive {:request_line, request_line}, 2_000
        request_line
      end

    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 2_000
    :gen_tcp.close(listener)
    {url, response, lines}
  end

  defp response_bytes(:ok),
    do: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"

  defp response_bytes(%Req.Response{status: 302} = response) do
    [location] = Req.Response.get_header(response, "location")

    "HTTP/1.1 302 Found\r\nLocation: #{location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  end

  defp request_headers(socket, bytes) do
    if String.contains?(bytes, "\r\n\r\n") do
      bytes
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
      request_headers(socket, bytes <> chunk)
    end
  end
end
