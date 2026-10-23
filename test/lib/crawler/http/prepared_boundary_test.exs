defmodule Crawler.HTTP.PreparedBoundaryTest do
  use ExUnit.Case, async: false

  alias Crawler.Deadline
  alias Crawler.Fetcher.Requester
  alias Crawler.HTTP
  alias Crawler.HTTP.BodyTooLarge
  alias Crawler.Limits
  alias Crawler.Store

  test "control accounting charges inflated entity bytes and keeps receipt sequences across sends in one lease" do
    with_control_context(6, 8, fn context ->
      adapter = fn request ->
        {request,
         Req.Response.new(
           status: 200,
           body: :zlib.gzip("abc"),
           headers: [{"content-encoding", "gzip"}]
         )}
      end

      assert {:ok, prepared} = control_prepare(context, adapter)
      assert {:ok, first} = Requester.send(prepared, context)
      assert {:ok, second} = Requester.send(prepared, context)
      assert first.body == "abc"
      assert second.body == "abc"
      first_sequence = Req.Response.get_private(first, :crawler_control_sequence)
      second_sequence = Req.Response.get_private(second, :crawler_control_sequence)
      assert is_integer(first_sequence) and first_sequence > 0
      assert second_sequence > first_sequence
      assert {:error, {:limit, :max_control_bytes}} = Requester.send(prepared, context)
    end)
  end

  test "every redirect body counts before the final control response" do
    with_control_context(6, 8, fn context ->
      owner = self()

      adapter = fn request ->
        send(owner, {:control_hop, request.url.path})

        response =
          if request.url.path == "/start",
            do: Req.Response.new(status: 302, body: "abc", headers: [{"location", "/last"}]),
            else: Req.Response.new(status: 200, body: "defg")

        {request, response}
      end

      assert {:ok, prepared} = control_prepare(context, adapter)
      assert {:error, {:limit, :max_control_bytes}} = Requester.send(prepared, context)
      assert_receive {:control_hop, "/start"}
      assert_receive {:control_hop, "/last"}
      refute_received {:control_hop, _}
    end)
  end

  test "a final gzip-file expansion upgrades its HTTP receipt by only the additional bytes" do
    with_control_context(45, 128, fn context ->
      gzip = :zlib.gzip(:binary.copy("a", 40))
      adapter = fn request -> {request, Req.Response.new(status: 200, body: gzip)} end
      assert {:ok, prepared} = control_prepare(context, adapter)
      assert {:ok, response} = Requester.send(prepared, context)
      assert response.body == gzip
      assert byte_size(:zlib.gunzip(response.body)) == 40
      sequence = Req.Response.get_private(response, :crawler_control_sequence)
      outer_context = Map.put(context, :control_sequence, sequence)
      assert :ok = Store.account_control_bytes(outer_context, 40)
      assert :ok = Store.account_control_bytes(outer_context, 40)

      small = fn request -> {request, Req.Response.new(status: 200, body: "12345")} end
      assert {:ok, prepared} = control_prepare(context, small)
      assert {:ok, _} = Requester.send(prepared, context)
      assert {:error, {:limit, :max_control_bytes}} = Requester.send(prepared, context)
    end)
  end

  test "accounting rejection is terminal before response cookies, retry callbacks and redirect hops" do
    for status <- [302, 503] do
      with_control_context(2, 8, fn context ->
        owner = self()

        adapter = fn request ->
          send(owner, :control_transport)

          {request,
           Req.Response.new(
             status: status,
             body: "abc",
             headers: [
               {"location", "/last"},
               {"set-cookie", "forbidden=one; Path=/; Secure"}
             ]
           )}
        end

        retry = fn _, _ ->
          send(owner, :control_retry)
          true
        end

        assert {:ok, prepared} = control_prepare(context, adapter, retry: retry, retry_delay: 0)
        assert {:error, {:limit, :max_control_bytes}} = Requester.send(prepared, context)
        assert_receive :control_transport
        refute_received :control_transport
        refute_received :control_retry
        assert Store.cookie_header(context.scope, "https://seed.test/", context.generation) == nil
      end)
    end
  end

  test "a failed transport charges max_body once before the retry callback" do
    with_control_context(5, 4, fn context ->
      owner = self()
      failed = fn request -> {request, %Req.TransportError{reason: :closed}} end
      assert {:ok, prepared} = control_prepare(context, failed)
      assert {:error, %Req.TransportError{reason: :closed}} = Requester.send(prepared, context)

      small = fn request -> {request, Req.Response.new(status: 200, body: "x")} end
      assert {:ok, prepared} = control_prepare(context, small)
      assert {:ok, %Req.Response{body: "x"}} = Requester.send(prepared, context)
      assert {:error, {:limit, :max_control_bytes}} = Requester.send(prepared, context)
      refute_received :control_retry

      retry = fn _, _ ->
        send(owner, :control_retry)
        true
      end

      assert {:ok, prepared} = control_prepare(context, failed, retry: retry, retry_delay: 0)
      assert {:error, {:limit, :max_control_bytes}} = Requester.send(prepared, context)
      refute_received :control_retry
    end)
  end

  test "body failures charge max_body once and keep their existing public error when the control budget permits" do
    with_control_context(5, 4, fn context ->
      large = fn request ->
        {request,
         Req.Response.new(
           status: 200,
           body: :zlib.gzip("12345"),
           headers: [{"content-encoding", "gzip"}]
         )}
      end

      assert {:ok, prepared} = control_prepare(context, large)
      assert {:error, %BodyTooLarge{max_body: 4}} = Requester.send(prepared, context)

      small = fn request -> {request, Req.Response.new(status: 200, body: "x")} end
      assert {:ok, prepared} = control_prepare(context, small)
      assert {:ok, %Req.Response{body: "x"}} = Requester.send(prepared, context)
      assert {:error, {:limit, :max_control_bytes}} = Requester.send(prepared, context)
    end)
  end

  test "raised and thrown transport failures charge once while preserving their original outcome" do
    for failure <- [:raise, :throw] do
      with_control_context(5, 4, fn context ->
        failed = fn _request ->
          if failure == :raise, do: raise("adapter failed"), else: throw(:adapter_failed)
        end

        assert {:ok, prepared} = control_prepare(context, failed)

        if failure == :raise do
          assert_raise RuntimeError, "adapter failed", fn -> Requester.send(prepared, context) end
        else
          assert catch_throw(Requester.send(prepared, context)) == :adapter_failed
        end

        small = fn request -> {request, Req.Response.new(status: 200, body: "x")} end
        assert {:ok, prepared} = control_prepare(context, small)
        assert {:ok, _} = Requester.send(prepared, context)
        assert {:error, {:limit, :max_control_bytes}} = Requester.send(prepared, context)
      end)
    end
  end

  test "accounting rejection turns a raised transport failure into the terminal budget outcome" do
    with_control_context(2, 4, fn context ->
      owner = self()
      failed = fn _request -> raise "adapter failed" end

      retry = fn _, _ ->
        send(owner, :control_retry)
        true
      end

      assert {:ok, prepared} = control_prepare(context, failed, retry: retry)
      assert {:error, {:limit, :max_control_bytes}} = Requester.send(prepared, context)
      refute_received :control_retry
    end)
  end

  test "make and call do not accept a caller control-accounting flag" do
    for entrypoint <- [:make, :call] do
      with_control_context(3, 4, fn context ->
        adapter = fn request -> {request, Req.Response.new(status: 200, body: "abc")} end

        opts =
          Map.merge(context, %{url: "https://seed.test/start", req_options: [adapter: adapter]})

        assert {:ok, direct} = apply(Requester, entrypoint, [opts])
        assert Req.Response.get_private(direct, :crawler_control_sequence) == nil
        assert {:ok, prepared} = control_prepare(context, adapter)
        assert {:ok, _response} = Requester.send(prepared, context)
        assert {:error, {:limit, :max_control_bytes}} = Requester.send(prepared, context)
      end)
    end
  end

  test "expiry charges only the current active first or second redirect transport" do
    for {blocked_path, expected} <- [{"/start", 4}, {"/last", 5}] do
      assert_control_expiry_cost(expected, fn context, owner ->
        adapter = fn request ->
          if request.url.path == blocked_path do
            hold_control_interval(owner)
          end

          {request, Req.Response.new(status: 302, body: "a", headers: [{"location", "/last"}])}
        end

        assert {:ok, prepared} = control_prepare(context, adapter)
        Requester.send(prepared, context)
      end)
    end
  end

  test "retry backoff and parsing after a closed transport incur no unknown-body expiry cost" do
    for phase <- [:backoff, :parsing] do
      assert_control_expiry_cost(1, fn context, owner ->
        status = if phase == :backoff, do: 503, else: 200
        adapter = fn request -> {request, Req.Response.new(status: status, body: "a")} end

        req_options =
          if phase == :backoff do
            [retry: fn _, _ -> true end, retry_delay: fn _ -> hold_control_interval(owner) end]
          else
            []
          end

        assert {:ok, prepared} = control_prepare(context, adapter, req_options)
        assert {:ok, _response} = Requester.send(prepared, context)
        hold_control_interval(owner)
      end)
    end
  end

  test "nested sends balance independent transport intervals under one execution lease" do
    for {phase, expected} <- [{:both_active, 8}, {:outer_active, 5}, {:closed, 2}] do
      assert_control_expiry_cost(expected, fn context, owner ->
        inner_adapter = fn request ->
          if phase == :both_active, do: hold_control_interval(owner)
          {request, Req.Response.new(status: 200, body: "a")}
        end

        assert {:ok, inner} = control_prepare(context, inner_adapter)

        outer_adapter = fn request ->
          assert {:ok, _response} = Requester.send(inner, context)
          if phase == :outer_active, do: hold_control_interval(owner)
          {request, Req.Response.new(status: 200, body: "b")}
        end

        assert {:ok, outer} = control_prepare(context, outer_adapter)
        assert {:ok, _response} = Requester.send(outer, context)
        hold_control_interval(owner)
      end)
    end
  end

  test "a response plugin failure after Body finalization adds no unknown-body charge" do
    with_control_context(20, 4, fn context ->
      plugin = fn request ->
        Req.Request.prepend_response_steps(request,
          fail_after_body: fn _result -> raise "response parsing failed" end
        )
      end

      adapter = fn request -> {request, Req.Response.new(status: 200, body: "a")} end
      assert {:ok, prepared} = control_prepare(context, adapter, plugins: [plugin])

      assert_raise RuntimeError, "response parsing failed", fn ->
        Requester.send(prepared, context)
      end

      assert control_bytes(context.scope) == 1
      assert :ok = Store.expire_execution(self())
      assert control_bytes(context.scope) == 1
    end)
  end

  test "raised and thrown adapters close their active interval after unknown-body accounting" do
    for failure <- [:raise, :throw] do
      with_control_context(20, 4, fn context ->
        adapter = fn _request ->
          if failure == :raise, do: raise("adapter failed"), else: throw(:adapter_failed)
        end

        assert {:ok, prepared} = control_prepare(context, adapter)

        if failure == :raise do
          assert_raise RuntimeError, "adapter failed", fn -> Requester.send(prepared, context) end
        else
          assert catch_throw(Requester.send(prepared, context)) == :adapter_failed
        end

        assert control_bytes(context.scope) == 4
        assert :ok = Store.expire_execution(self())
        assert control_bytes(context.scope) == 4
      end)
    end
  end

  test "a rejected transport start does not dispatch or charge an unknown body" do
    with_control_context(20, 4, fn context ->
      adapter = fn _request -> flunk("rejected transport dispatched") end
      assert {:ok, prepared} = control_prepare(context, adapter)
      assert {:error, :stale} = Requester.send(prepared, %{context | execution_lease: nil})
      assert control_bytes(context.scope) == 0
      assert :ok = Store.expire_execution(self())
      assert control_bytes(context.scope) == 0
    end)
  end

  test "a monitored deadline keeps its public result while charging an active silent transport" do
    scope = "control-deadline-#{System.unique_integer([:positive])}"
    generation = Store.generation(scope)
    owner = self()
    deadline = Deadline.after_ms(150)

    assert {:error, {:deadline, :attempt}} =
             Deadline.run(
               deadline,
               fn ->
                 opts =
                   Map.merge(Limits.defaults(), %{
                     scope: scope,
                     generation: generation,
                     queue: nil,
                     max_body: 4,
                     max_control_bytes: 20,
                     control_accounting: true
                   })

                 assert {:ok, lease} = Store.begin_execution(opts, deadline)
                 context = Map.merge(opts, %{execution_lease: lease, crawler_deadline: deadline})
                 adapter = fn _request -> hold_control_interval(owner) end
                 assert {:ok, prepared} = control_prepare(context, adapter)
                 Requester.send(prepared, context)
               end,
               &Store.expire_execution/1
             )

    assert_receive {:control_interval, _worker}
    assert control_bytes(scope) == 4
  end

  defp hold_control_interval(owner) do
    send(owner, {:control_interval, self()})

    receive do
      :release_control_interval -> :ok
    end
  end

  defp assert_control_expiry_cost(expected, callback) do
    scope = "control-expiry-#{System.unique_integer([:positive])}"
    generation = Store.generation(scope)
    owner = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        opts =
          Map.merge(Limits.defaults(), %{
            scope: scope,
            generation: generation,
            queue: nil,
            max_body: 4,
            max_control_bytes: 20,
            control_accounting: true
          })

        deadline = Deadline.after_ms(30_000)
        assert {:ok, lease} = Store.begin_execution(opts, deadline)
        context = Map.merge(opts, %{execution_lease: lease, crawler_deadline: deadline})
        callback.(context, owner)
      end)

    try do
      assert_receive {:control_interval, ^worker}, 2000
      assert :ok = Store.expire_execution(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2000
      assert control_bytes(scope) == expected
    after
      Process.exit(worker, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp control_bytes(scope), do: :sys.get_state(Store).scopes[scope].control_bytes

  defp control_prepare(context, adapter, req_options \\ []) do
    Requester.prepare(%{
      scope: context.scope,
      generation: context.generation,
      url: "https://seed.test/start",
      site: "https://seed.test/",
      max_body: context.max_body,
      req_options: Keyword.merge([adapter: adapter], req_options)
    })
  end

  defp with_control_context(control_bytes, max_body, callback) do
    scope = "control-boundary-#{System.unique_integer([:positive])}"
    generation = Store.generation(scope)

    opts =
      Map.merge(Limits.defaults(), %{
        scope: scope,
        generation: generation,
        queue: nil,
        max_body: max_body,
        max_control_bytes: control_bytes,
        control_accounting: true
      })

    deadline = Deadline.after_ms(5000)
    assert {:ok, lease} = Store.begin_execution(opts, deadline)
    context = Map.merge(opts, %{execution_lease: lease, crawler_deadline: deadline})

    try do
      callback.(context)
    after
      Store.end_execution(lease)
    end
  end

  test "opaque response steps that discard proof metadata still send normally and cannot share" do
    plugin = fn request ->
      Req.Request.append_response_steps(request,
        discard_proof: fn {request, response} ->
          {%{request | private: Map.delete(request.private, :crawler_cookie_trace)}, response}
        end
      )
    end

    adapter = fn request -> {request, Req.Response.new(status: 200, body: "OK")} end

    assert {:ok, response} =
             Requester.make(%{
               url: "https://seed.test/",
               req_options: [adapter: adapter, plugins: [plugin]]
             })

    assert response.body == "OK"
    assert Requester.reuse_disposition(response).disposition == :private
  end

  test "direct HTTP preset bodies pass bounded Body before any Req decompression or decoding" do
    for body <- [
          "12345",
          ["12", ~c"345"],
          :zlib.gzip(:binary.copy("a", 200_000)),
          [:zlib.gzip(:binary.copy("a", 200_000))]
        ] do
      compressed = body not in ["12345", ["12", ~c"345"]]
      headers = if compressed, do: [{"content-encoding", "gzip"}], else: []
      owner = self()

      adapter = fn request ->
        send(owner, {:pipeline, Keyword.keys(request.response_steps)})
        {request, Req.Response.new(status: 200, body: body, headers: headers)}
      end

      assert {:error, %BodyTooLarge{max_body: 4}} =
               HTTP.get("https://seed.test/a", [],
                 adapter: adapter,
                 crawler_max_body: 4,
                 compressed: true,
                 decode_body: true,
                 retry: false
               )

      assert_receive {:pipeline, steps}
      assert hd(steps) == :crawler_body
      refute :decompress_body in steps
      refute :decode_body in steps
    end
  end

  test "direct HTTP bounded gzip output is decoded exactly once even with global decode options" do
    adapter = fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: :zlib.gzip("1234"),
         headers: [{"content-encoding", "gzip"}]
       )}
    end

    assert {:ok, %Req.Response{body: "1234"}} =
             HTTP.get("https://seed.test/a", [],
               adapter: adapter,
               crawler_max_body: 4,
               compressed: true,
               decode_body: true,
               retry: false
             )
  end

  test "oversized redirect and retry responses terminate before another transport" do
    owner = self()

    adapter = fn request ->
      send(owner, :transport)
      {request, Req.Response.new(status: 503, body: "too long", headers: [{"location", "/last"}])}
    end

    assert {:error, %BodyTooLarge{}} =
             HTTP.get("https://seed.test/a", [],
               adapter: adapter,
               crawler_max_body: 1,
               retry: fn _, _ -> true end,
               retry_delay: 0
             )

    assert_receive :transport
    refute_received :transport
  end

  test "expired supplied deadlines return the tagged outcome before transport" do
    owner = self()

    adapter = fn request ->
      send(owner, :transport)
      {request, Req.Response.new(status: 200)}
    end

    assert {:ok, prepared} =
             Requester.prepare(%{url: "https://seed.test/a", req_options: [adapter: adapter]})

    assert {:error, {:deadline, :run}} =
             Requester.send(prepared, deadline: Deadline.after_ms(0, :run))

    refute_received :transport
  end

  test "a late custom adapter result becomes a deadline outcome" do
    deadline = Deadline.after_ms(20)

    adapter = fn request ->
      Process.sleep(30)
      {request, Req.Response.new(status: 200, body: "late")}
    end

    assert {:error, {:deadline, :attempt}} =
             HTTP.get("https://seed.test/a", [],
               adapter: adapter,
               crawler_deadline: deadline,
               retry: false
             )
  end

  test "retry backoff respects one absolute deadline and does not make another transport" do
    owner = self()
    deadline = Deadline.after_ms(30)

    adapter = fn request ->
      send(owner, {:transport, request.options[:crawler_deadline]})
      {request, Req.Response.new(status: 503, body: "retry", headers: [{"retry-after", "9999"}])}
    end

    started = Deadline.now()

    assert {:error, {:deadline, :attempt}} =
             HTTP.get("https://seed.test/a", [],
               adapter: adapter,
               crawler_deadline: deadline,
               retry: :transient,
               max_retries: 4,
               retry_log_level: false
             )

    assert Deadline.now() - started < 500
    assert_receive {:transport, ^deadline}
    refute_received {:transport, _}
  end

  test "retries keep the frozen request and unchanged deadline" do
    owner = self()

    adapter = fn request ->
      count = Req.Request.get_private(request, :req_retry_count, 0)
      send(owner, {:transport, request.headers, request.options[:crawler_deadline]})
      {request, Req.Response.new(status: if(count == 0, do: 503, else: 200), body: "OK")}
    end

    deadline = Deadline.after_ms(1000, :run)

    assert {:ok, prepared} =
             Requester.prepare(%{
               url: "https://seed.test/a",
               req_options: [
                 adapter: adapter,
                 auth: {:bearer, "frozen"},
                 retry: :transient,
                 retry_delay: 0
               ]
             })

    assert {:ok, %Req.Response{status: 200}} = Requester.send(prepared, deadline: deadline)
    headers = prepared.request.headers
    assert_receive {:transport, ^headers, ^deadline}
    assert_receive {:transport, ^headers, ^deadline}
    refute_received {:transport, _, _}
  end

  test "redirect policy time consumes the same absolute deadline" do
    owner = self()

    adapter = fn request ->
      send(owner, {:transport, request.url.path})
      {request, Req.Response.new(status: 302, headers: [{"location", "/last"}], body: "redirect")}
    end

    allow = fn _url ->
      Process.sleep(25)
      true
    end

    assert {:error, {:deadline, :attempt}} =
             HTTP.get(
               "https://seed.test/a",
               [],
               [adapter: adapter, retry: false, crawler_deadline: Deadline.after_ms(15)],
               allow
             )

    assert_receive {:transport, "/a"}
    refute_received {:transport, _}
  end

  test "a rejected redirect closes compressed body state and returns the existing contract" do
    adapter = fn request ->
      response =
        Req.Response.new(
          status: 302,
          headers: [{"location", "https://foreign.test/"}, {"content-encoding", "gzip"}]
        )

      {:cont, result} = request.into.({:data, :zlib.gzip("redirect")}, {request, response})
      result
    end

    assert {:error, %HTTP.RedirectRejected{}} =
             HTTP.get("https://seed.test/a", [], [adapter: adapter, retry: false], fn _ ->
               false
             end)
  end

  test "adapter error cleanup releases active inflate state and preserves the error contract" do
    owner = self()

    adapter = fn request ->
      response = Req.Response.new(status: 200, headers: [{"content-encoding", "gzip"}])
      gzip = :zlib.gzip(:binary.copy("a", 1000))

      {:cont, {request, response}} =
        request.into.({:data, binary_part(gzip, 0, 10)}, {request, response})

      state = Req.Response.get_private(response, :crawler_body)
      send(owner, {:decoder, hd(state.layers).z})
      {request, %Req.TransportError{reason: :closed}}
    end

    assert {:error, %Req.TransportError{reason: :closed}} =
             HTTP.get("https://seed.test/a", [], adapter: adapter, retry: false)

    assert_receive {:decoder, zlib}
    assert catch_error(:zlib.safeInflate(zlib, "")) == :not_initialized
  end

  test "one supported Finch callback can select live wire credentials but its repeated responses stay private" do
    {:ok, session} = Agent.start_link(fn -> "A" end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()

    server =
      spawn_link(fn ->
        for _ <- 1..2 do
          {:ok, socket} = :gen_tcp.accept(listener, 2000)
          bytes = read_headers(socket, "")
          [_, token] = Regex.run(~r/authorization: Bearer ([^\r]+)/i, bytes)
          send(owner, {:deferred_wire, bytes})

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\nContent-Length: ",
              Integer.to_string(byte_size(token)),
              "\r\nConnection: close\r\n\r\n",
              token
            ])

          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
      if Process.alive?(session), do: Agent.stop(session)
    end)

    callback = fn request, finch, name, options ->
      token = Agent.get(session, & &1)

      finch = %{
        finch
        | headers:
            List.keystore(
              finch.headers,
              "authorization",
              0,
              {"authorization", "Bearer " <> token}
            )
      }

      case Finch.request(finch, name, options) do
        {:ok, response} -> {request, Req.Response.new(response)}
        {:error, exception} -> {request, exception}
      end
    end

    opts = %{
      url: "http://127.0.0.1:#{port}/session",
      req_options: [finch_request: callback, auth: {:bearer, "frozen"}]
    }

    assert {:ok, prepared} = Requester.prepare(opts)
    assert {:ok, separately_prepared} = Requester.prepare(opts)
    refute prepared.equivalence == separately_prepared.equivalence
    frozen = prepared.request
    refute_received {:deferred_wire, _}

    for token <- ["A", "B"] do
      Agent.update(session, fn _ -> token end)
      assert {:ok, response} = Requester.send(prepared)
      assert response.body == token
      assert_receive {:deferred_wire, bytes}
      assert bytes =~ "authorization: Bearer #{token}\r\n"
      assert prepared.request === frozen
      assert prepared.request.headers["authorization"] == ["Bearer frozen"]

      assert %{disposition: :private, reason: :opaque_behavior} =
               Requester.reuse_disposition(response)
    end
  end

  test "real cookie storage funding rejection is terminal for success, redirect and retry responses" do
    for status <- [200, 302, 503], deadline? <- [false, true] do
      owner = self()
      {scope, generation, before} = cookie_funding_fixture()

      adapter = fn request ->
        send(owner, :cookie_funding_transport)

        {request,
         Req.Response.new(
           status: status,
           body: "x",
           headers: [
             {"set-cookie", "arrived=partial; Path=/"},
             {"location", "/later"}
           ]
         )}
      end

      retry = fn _, _ ->
        send(owner, :cookie_funding_retry)
        true
      end

      plugin = fn request ->
        Req.Request.prepend_response_steps(request,
          after_cookie: fn result ->
            send(owner, :after_cookie_funding)
            result
          end
        )
      end

      opts =
        Crawler.Options.assign_defaults(%{
          url: "https://seed.test/start",
          scope: scope,
          generation: generation,
          max_cookie_bytes: 10_000_000,
          req_options: [adapter: adapter, retry: retry, retry_delay: 0, plugins: [plugin]]
        })

      opts = if deadline?, do: Map.put(opts, :deadline, Deadline.after_ms(5000)), else: opts
      assert opts.max_cookie_bytes > opts.max_retained_bytes / 8
      assert {:ok, prepared} = Requester.prepare(opts)
      assert {:error, {:limit, :max_retained_bytes}} = Requester.send(prepared)
      assert_receive :cookie_funding_transport
      refute_received :cookie_funding_transport
      refute_received :cookie_funding_retry
      refute_received :after_cookie_funding
      assert_cookie_funding_unchanged(scope, generation, before)
    end
  end

  test "direct HTTP returns a real cookie funding limit before redirect policy or retry" do
    owner = self()
    {scope, generation, before} = cookie_funding_fixture()

    adapter = fn request ->
      send(owner, :direct_cookie_funding_transport)

      {request,
       Req.Response.new(
         status: 302,
         body: "x",
         headers: [
           {"set-cookie", "arrived=partial; Path=/"},
           {"location", "/later"}
         ]
       )}
    end

    retry = fn _, _ ->
      send(owner, :direct_cookie_funding_retry)
      true
    end

    allow = fn _ ->
      send(owner, :direct_cookie_funding_redirect)
      true
    end

    assert {:error, {:limit, :max_retained_bytes}} =
             HTTP.get(
               "https://seed.test/start",
               [],
               [
                 crawler_scope: scope,
                 crawler_generation: generation,
                 max_cookie_bytes: 10_000_000,
                 adapter: adapter,
                 retry: retry,
                 retry_delay: 0
               ],
               allow
             )

    assert_receive :direct_cookie_funding_transport
    refute_received :direct_cookie_funding_transport
    refute_received :direct_cookie_funding_retry
    refute_received :direct_cookie_funding_redirect
    assert_cookie_funding_unchanged(scope, generation, before)
  end

  test "a trusted control cookie funding rejection keeps its decoded entity receipt and closes transport" do
    with_control_context(20, 4, fn context ->
      owner = self()
      before = :sys.get_state(Store)

      adapter = fn request ->
        send(owner, :control_cookie_funding_transport)

        {request,
         Req.Response.new(
           status: 302,
           body: :zlib.gzip("abc"),
           headers: [
             {"content-encoding", "gzip"},
             {"set-cookie", "arrived=partial; Path=/"},
             {"location", "/later"}
           ]
         )}
      end

      assert {:ok, prepared} =
               Requester.prepare(
                 Map.merge(context, %{
                   url: "https://seed.test/start",
                   max_cookie_bytes: 10_000_000,
                   req_options: [adapter: adapter]
                 })
               )

      assert {:error, {:limit, :max_retained_bytes}} = Requester.send(prepared, context)
      assert_receive :control_cookie_funding_transport
      refute_received :control_cookie_funding_transport
      assert control_bytes(context.scope) == 3
      assert :sys.get_state(Store).executions[context.execution_lease].control_active == 0
      assert_cookie_funding_unchanged(context.scope, context.generation, before)
      assert :ok = Store.expire_execution(self())
      assert control_bytes(context.scope) == 3
    end)
  end

  test "body errors precede cookie storage funding", do: assert_cookie_funding_precedence(:body)

  test "control errors precede cookie storage funding",
    do: assert_cookie_funding_precedence(:control)

  test "deadlines precede cookie storage funding", do: assert_cookie_funding_precedence(:deadline)

  test "stale authority precedes cookie storage funding",
    do: assert_cookie_funding_precedence(:stale)

  defp assert_cookie_funding_precedence(failure) do
    with_control_context(if(failure == :control, do: 1, else: 20), 4, fn context ->
      owner = self()

      adapter = fn request -> cookie_precedence_response(request, owner, failure, context) end

      assert {:ok, prepared} =
               Requester.prepare(
                 Map.merge(context, %{
                   url: "https://seed.test/start",
                   max_cookie_bytes: 10_000_000,
                   req_options: [adapter: adapter]
                 })
               )

      execution =
        if failure == :deadline,
          do: Map.put(context, :deadline, Deadline.after_ms(0)),
          else: context

      result = Requester.send(prepared, execution)

      case failure do
        :body -> assert {:error, %BodyTooLarge{max_body: 4}} = result
        :control -> assert result == {:error, {:limit, :max_control_bytes}}
        :deadline -> assert result == {:error, {:deadline, :attempt}}
        :stale -> assert result == {:error, :stale}
      end

      if failure == :deadline do
        refute_received {:cookie_precedence_transport, ^failure}
      else
        assert_receive {:cookie_precedence_transport, ^failure}
        refute_received {:cookie_precedence_transport, ^failure}
      end

      state = :sys.get_state(Store)
      refute Map.has_key?(state.cookies, context.scope)
      refute Map.has_key?(state.cookie_outcomes, context.scope)
    end)
  end

  defp cookie_precedence_response(request, owner, failure, context) do
    send(owner, {:cookie_precedence_transport, failure})
    if failure == :stale, do: Store.drop_scope(context.scope)

    {request,
     Req.Response.new(
       status: 302,
       body: if(failure == :body, do: "12345", else: "ab"),
       headers: [{"set-cookie", "arrived=partial; Path=/"}, {"location", "/later"}]
     )}
  end

  test "the cookie storage exception has a fixed message and redacted private reason" do
    exception = %HTTP.CookieStorageRejected{reason: {:private, "not-public"}}
    assert Exception.message(exception) == "response cookie storage rejected"
    refute inspect(exception) =~ "not-public"
  end

  defp cookie_funding_fixture do
    scope = "cookie-funding-#{System.unique_integer([:positive])}"
    generation = Store.generation(scope)
    Store.save_cookies(scope, "https://seed.test/", ["keep=original; Path=/"], generation)
    {scope, generation, :sys.get_state(Store)}
  end

  defp assert_cookie_funding_unchanged(scope, generation, before) do
    after_state = :sys.get_state(Store)
    assert after_state.cookies[scope] === before.cookies[scope]
    assert after_state.cookie_outcomes[scope] === before.cookie_outcomes[scope]
    assert after_state.cookie_bytes == before.cookie_bytes
    assert after_state.scopes[scope].cookie_revision == before.scopes[scope].cookie_revision
    context = %{site: "https://seed.test/", credentials: :include, navigation: true}
    assert {:ok, observation} = Store.validate_cookie_proof(scope, generation, context, :unbound)
    assert observation.effect == :unchanged
    assert observation.proof.cookie_revision == before.scopes[scope].cookie_revision
  end

  test "canonical nondefault cookie count, site, header, jar and update limits reach real response storage" do
    for {key, limit, headers, retained} <- [
          {:max_cookies, 1, ["a=1; Path=/", "b=2; Path=/"], "b=2"},
          {:max_cookies_per_site, 1, ["a=1; Path=/", "b=2; Path=/"], "b=2"},
          {:max_cookie_bytes, 16, ["id=" <> String.duplicate("x", 30)], nil},
          {:max_cookie_bytes, 16, ["id=x; Path=/; SameSite=Lax"], nil},
          {:max_cookie_jar_bytes, 1, ["id=x; Path=/"], nil},
          {:max_cookie_updates, 1, ["a=1; Path=/", "b=2; Path=/"], "a=1"}
        ] do
      scope = "cookie-policy-#{System.unique_integer([:positive])}"
      generation = Store.generation(scope)
      name = {__MODULE__, make_ref()}

      Req.Test.stub(name, fn conn ->
        Plug.Conn.send_resp(
          %{conn | resp_headers: Enum.map(headers, &{"set-cookie", &1})},
          200,
          "OK"
        )
      end)

      opts = %{
        url: "https://seed.test/",
        scope: scope,
        generation: generation,
        respect_robots: false,
        req_options: [plug: {Req.Test, name}]
      }

      opts = opts |> Map.put(key, limit) |> Crawler.Options.assign_defaults()
      assert {:ok, prepared} = Requester.prepare(opts)
      assert prepared.context.cookie_limits == Crawler.Limits.cookies(opts)
      assert {:ok, _response} = Requester.send(prepared)
      assert Store.cookie_header(scope, opts.url, generation) == retained
      outcome = :sys.get_state(Store).cookie_outcomes[scope]
      assert outcome.status == :limited
      assert key in outcome.limits
      if key == :max_cookie_updates, do: assert(outcome.processed == 1 and outcome.unprocessed?)
    end
  end

  test "each redirect save uses frozen canonical cookie limits despite application and raw Req policy changes" do
    original = Application.fetch_env(:crawler, :max_cookie_updates)
    scope = "cookie-redirect-policy-#{System.unique_integer([:positive])}"
    generation = Store.generation(scope)
    owner = self()
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/start" ->
          Plug.Conn.send_resp(
            %{
              conn
              | resp_headers: [
                  {"location", "/last"},
                  {"set-cookie", "a=1; Path=/"},
                  {"set-cookie", "b=2; Path=/"}
                ]
            },
            302,
            "first"
          )

        "/last" ->
          send(
            owner,
            {:redirect_policy_cookie, Plug.Conn.get_req_header(conn, "cookie"),
             :sys.get_state(Store).cookie_outcomes[scope]}
          )

          Plug.Conn.send_resp(
            %{
              conn
              | resp_headers: [{"set-cookie", "c=3; Path=/"}, {"set-cookie", "d=4; Path=/"}]
            },
            200,
            "last"
          )
      end
    end)

    plugin = fn request ->
      request
      |> Req.Request.register_options([:max_cookie_updates])
      |> Req.Request.put_option(:max_cookie_updates, 99)
      |> Req.Request.put_private(:crawler_cookie_limits, %{max_cookie_updates: 99})
      |> Req.Request.prepend_response_steps(
        replace_cookie_policy: fn {request, response} ->
          {Req.Request.put_private(request, :crawler_cookie_limits, %{max_cookie_updates: 99}),
           response}
        end
      )
    end

    try do
      Application.put_env(:crawler, :max_cookie_updates, 1)

      opts =
        Crawler.Options.assign_defaults(%{
          url: "https://seed.test/start",
          site: "https://seed.test/",
          scope: scope,
          generation: generation,
          respect_robots: false,
          req_options: [plug: {Req.Test, name}, plugins: [plugin], max_cookie_updates: 99]
        })

      assert {:ok, prepared} = Requester.prepare(opts)
      assert prepared.context.cookie_limits.max_cookie_updates == 1
      Application.put_env(:crawler, :max_cookie_updates, 99)
      assert {:ok, %Req.Response{body: "last"}} = Requester.send(prepared)
      assert_receive {:redirect_policy_cookie, ["a=1"], first_outcome}
      assert first_outcome.limits == [:max_cookie_updates]
      assert first_outcome.processed == 1
      assert Store.cookie_header(scope, "https://seed.test/", generation) == "a=1; c=3"
      assert :sys.get_state(Store).cookie_outcomes[scope].limits == [:max_cookie_updates]
    after
      case original do
        {:ok, value} -> Application.put_env(:crawler, :max_cookie_updates, value)
        :error -> Application.delete_env(:crawler, :max_cookie_updates)
      end
    end
  end

  test "direct HTTP normalizes top-level cookie limits through the same canonical boundary" do
    scope = "direct-cookie-policy-#{System.unique_integer([:positive])}"
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      Plug.Conn.send_resp(
        %{conn | resp_headers: [{"set-cookie", "a=1; Path=/"}, {"set-cookie", "b=2; Path=/"}]},
        200,
        "OK"
      )
    end)

    assert {:ok, %Req.Response{body: "OK"}} =
             HTTP.get("https://seed.test/", [],
               crawler_scope: scope,
               max_cookie_updates: 1,
               plug: {Req.Test, name},
               retry: false
             )

    assert Store.cookie_header(scope, "https://seed.test/") == "a=1"
    assert :sys.get_state(Store).cookie_outcomes[scope].limits == [:max_cookie_updates]
  end

  test "real Finch wire bytes retain the frozen credentials and ordered duplicate header values" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        bytes = read_headers(socket, "")
        send(owner, {:wire, bytes})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
        )

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end)

    opts = %{
      url: "http://127.0.0.1:#{port}/wire",
      req_options: [
        auth: {:bearer, "frozen"},
        headers: [
          {"x-repeat", ["first", "second"]},
          {"cookie", "id=account; id=root; extra=caller"}
        ],
        params: [page: "one"]
      ]
    }

    assert {:ok, prepared} = Requester.prepare(opts)
    assert {:ok, equivalent} = Requester.prepare(opts)
    assert prepared.equivalence == equivalent.equivalence
    assert {:ok, %Req.Response{body: "OK"}} = Requester.send(prepared)
    assert_receive {:wire, bytes}
    assert bytes =~ "GET /wire?page=one HTTP/1.1\r\n"
    assert bytes =~ "authorization: Bearer frozen\r\n"
    assert bytes =~ "cookie: id=account; id=root; extra=caller\r\n"
    assert bytes =~ "x-repeat: first\r\nx-repeat: second\r\n"
  end

  test "deadline expiry and a raised custom adapter both release active inflate state" do
    owner = self()

    for failure <- [:deadline, :raised] do
      adapter = fn request ->
        response = Req.Response.new(status: 200, headers: [{"content-encoding", "gzip"}])
        gzip = :zlib.gzip(:binary.copy("a", 1000))

        {:cont, {request, response}} =
          request.into.({:data, binary_part(gzip, 0, 10)}, {request, response})

        state = Req.Response.get_private(response, :crawler_body)
        send(owner, {:decoder, hd(state.layers).z})

        case failure do
          :deadline ->
            Process.sleep(25)
            {request, response}

          :raised ->
            raise "adapter failed"
        end
      end

      case failure do
        :deadline ->
          assert {:error, {:deadline, :attempt}} =
                   HTTP.get("https://seed.test/", [],
                     adapter: adapter,
                     retry: false,
                     crawler_deadline: Deadline.after_ms(15)
                   )

        :raised ->
          assert_raise RuntimeError, "adapter failed", fn ->
            HTTP.get("https://seed.test/", [], adapter: adapter, retry: false)
          end
      end

      assert_receive {:decoder, zlib}
      assert catch_error(:zlib.safeInflate(zlib, "")) == :not_initialized
    end
  end

  test "execution context cannot extend a deadline already frozen in preparation" do
    owner = self()

    adapter = fn request ->
      send(owner, :transport)
      {request, Req.Response.new(status: 200)}
    end

    run = Deadline.after_ms(10, :run)

    assert {:ok, prepared} =
             Requester.prepare(%{
               url: "https://seed.test/",
               deadline: run,
               req_options: [adapter: adapter]
             })

    Process.sleep(15)

    assert {:error, {:deadline, :run}} =
             Requester.send(prepared, deadline: Deadline.after_ms(1000))

    refute_received :transport
  end

  test "direct HTTP retains documented same-host headers through scheme and port changes" do
    owner = self()

    adapter = fn request ->
      send(owner, {:headers, request.url.scheme, request.headers})

      response =
        if request.url.scheme == "https",
          do:
            Req.Response.new(status: 302, headers: [{"location", "http://seed.test:8080/last"}]),
          else: Req.Response.new(status: 200, body: "OK")

      {request, response}
    end

    assert {:ok, _} =
             HTTP.get(
               "https://seed.test/first",
               [{"cookie", "caller=one"}, {"x-secret", "retained"}],
               adapter: adapter,
               auth: {:bearer, "retained"},
               retry: false
             )

    assert_receive {:headers, "https", _}
    assert_receive {:headers, "http", last}
    assert last["authorization"] == ["Bearer retained"]
    assert last["cookie"] == ["caller=one"]
    assert last["x-secret"] == ["retained"]
  end

  test "an opaque request step cannot disable the bounded stream callback" do
    owner = self()

    plugin = fn request ->
      Req.Request.append_request_steps(request,
        disable_into: fn request -> %{request | into: nil} end
      )
    end

    adapter = fn request ->
      send(owner, {:into, request.into})

      {request,
       Req.Response.new(
         status: 200,
         body: :zlib.gzip("oversized"),
         headers: [{"content-encoding", "gzip"}]
       )}
    end

    assert {:error, %BodyTooLarge{}} =
             HTTP.get("https://seed.test/", [],
               adapter: adapter,
               plugins: [plugin],
               crawler_max_body: 1,
               retry: false
             )

    assert_receive {:into, callback}
    assert is_function(callback, 2)
  end

  test "explicit redirect logging removes URL credentials" do
    adapter = fn request ->
      response =
        if request.url.path == "/first",
          do:
            Req.Response.new(
              status: 302,
              headers: [{"location", "https://private-user:private-password@seed.test/last"}]
            ),
          else: Req.Response.new(status: 200, body: "OK")

      {request, response}
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} =
                 HTTP.get("https://seed.test/first", [],
                   adapter: adapter,
                   retry: false,
                   redirect_log_level: :info
                 )
      end)

    assert log =~ "redirecting to https://seed.test/last"
    refute log =~ "private-user"
    refute log =~ "private-password"
  end

  test "preset encoding caps return tagged limit outcomes before decoding or retries" do
    owner = self()

    for {key, headers} <- encoding_limits(), body <- ["preset", ["pre", ~c"set"]] do
      adapter = fn request ->
        send(owner, :transport)
        {request, Req.Response.new(status: 503, headers: headers, body: body)}
      end

      retry = fn _, _ ->
        send(owner, :retry)
        true
      end

      assert {:error, {:limit, ^key}} =
               HTTP.get("https://seed.test/limited", [],
                 adapter: adapter,
                 retry: retry,
                 retry_delay: 0
               )

      assert_receive :transport
      refute_received :transport
      refute_received :retry
    end
  end

  test "encoding cap on a redirect returns its limit before redirect policy or another hop" do
    owner = self()

    for {key, headers} <- encoding_limits() do
      adapter = fn request ->
        send(owner, {:transport, request.url.path})

        {request,
         Req.Response.new(status: 302, headers: [{"location", "/last"} | headers], body: "preset")}
      end

      allow = fn _ ->
        send(owner, :redirect_policy)
        true
      end

      retry = fn _, _ ->
        send(owner, :retry)
        true
      end

      assert {:error, {:limit, ^key}} =
               HTTP.get(
                 "https://seed.test/first",
                 [],
                 [adapter: adapter, retry: retry, retry_delay: 0],
                 allow
               )

      assert_receive {:transport, "/first"}
      refute_received {:transport, _}
      refute_received :redirect_policy
      refute_received :retry
    end
  end

  test "prepared adapter encoding limit exceptions normalize and remain terminal for custom retries" do
    owner = self()

    for {key, limit} <- [content_encoding_bytes: 8192, content_encoding_layers: 8],
        deadline <- [nil, Deadline.after_ms(1000)] do
      adapter = fn request ->
        send(owner, :transport)
        {request, %Crawler.HTTP.BodyLimitExceeded{key: key, limit: limit, reason: {:limit, key}}}
      end

      retry = fn _, _ ->
        send(owner, :retry)
        true
      end

      assert {:ok, prepared} =
               Requester.prepare(%{
                 url: "https://seed.test/limited",
                 req_options: [adapter: adapter, retry: retry, retry_delay: 0]
               })

      assert {:error, {:limit, ^key}} = Requester.send(prepared, deadline: deadline)
      assert_receive :transport
      refute_received :transport
      refute_received :retry
    end
  end

  defp encoding_limits do
    [
      {:content_encoding_bytes, [{"content-encoding", String.duplicate("x", 8193)}]},
      {:content_encoding_layers,
       [{"content-encoding", Enum.join(List.duplicate("gzip", 9), ", ")}]}
    ]
  end

  defp read_headers(socket, bytes) do
    if String.contains?(bytes, "\r\n\r\n") do
      bytes
    else
      {:ok, next} = :gen_tcp.recv(socket, 0, 2000)
      read_headers(socket, bytes <> next)
    end
  end
end
