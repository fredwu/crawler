defmodule Crawler.Phase2.RepresentationIntegrationTest do
  use ExUnit.Case, async: false

  alias Crawler.Store

  defmodule Parser do
    def parse(%Crawler.Store.Page{} = page) do
      if pid = page.opts[:representation_observer],
        do: send(pid, {:interpreted, page.opts.javascript_goal, page.body})

      {:ok, page}
    end

    def parse(_), do: :ok
  end

  defmodule CapturingFilter do
    def filter(_url, opts) do
      send(opts.representation_observer, {:filtered, opts.html_tag})
      {:ok, true}
    end
  end

  defmodule HeldStore do
    def add_page_data(key, body, opts) do
      result = Store.add_page_data(key, body, opts, opts.generation, opts.queue)
      send(opts.representation_observer, {:stored_variant, body, self()})

      if body == "first" do
        receive do
          :continue_variant -> :ok
        end
      end

      result
    end
  end

  defmodule BackoffRetrier do
    use Retry

    def perform(callback, opts) do
      retry with: Stream.take(constant_backoff(60_000), 1), atoms: [:error], rescue_only: [] do
        result = callback.()

        if opts.javascript_goal == :script and match?({:error, _}, result) do
          send(opts.representation_observer, {:retry_result, self(), opts.target_handle})

          receive do
            :enter_backoff -> :ok
          end
        end

        result
      end
    end
  end

  defmodule LocalFailureRetrier do
    def perform(callback, opts) do
      result = callback.()

      if opts.javascript_goal == :script do
        send(opts.representation_observer, {:local_result, self(), opts.target_handle})

        receive do
          :fail_locally -> :ok
        end

        case opts.failure_kind do
          :error -> raise "local retrier failure"
          :throw -> throw(:local_retrier_failure)
          :exit -> exit(:local_retrier_failure)
        end
      end

      result
    end
  end

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    scope = make_ref()
    {:links, before_links} = Process.info(self(), :links)
    {:ok, queue} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 2, timeout: 5_000)
    {:links, after_links} = Process.info(self(), :links)
    children = after_links -- before_links
    Enum.each(children, &Process.unlink/1)

    on_exit(fn ->
      Store.dispose_scope(scope)
      Enum.each(children, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    end)

    %{scope: scope, queue: queue}
  end

  test "compatible goals share one frozen response and terminal failures fan out", context do
    for status <- [200, 503] do
      scope = {context.scope, status}
      on_exit(fn -> Store.dispose_scope(scope) end)
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      adapter = fn request ->
        Agent.update(calls, &(&1 + 1))

        {request,
         Req.Response.new(
           status: status,
           body: "let x = 1;",
           headers: [{"content-type", "text/javascript"}]
         )}
      end

      opts = options(%{context | scope: scope}, adapter)
      OPQ.pause(context.queue)
      assert {:paused, _, _} = OPQ.info(context.queue)

      {:ok, classic} =
        Crawler.crawl(
          "https://representation.test/script",
          Keyword.put(opts, :javascript_goal, :script)
        )

      {:ok, module} =
        Crawler.crawl(
          "https://representation.test/script",
          Keyword.put(opts, :javascript_goal, :module)
        )

      assert classic.target_handle != module.target_handle
      OPQ.resume(context.queue)

      await(fn ->
        assert %{status: outcome} = Store.target_outcome(classic.target_handle)
        assert %{status: ^outcome} = Store.target_outcome(module.target_handle)
        assert outcome == if(status == 200, do: :succeeded, else: :failed)
      end)

      assert Agent.get(calls, & &1) == 1
      before = :sys.get_state(Store).scheduler.frontier

      for _ <- 1..50 do
        {:ok, duplicate} =
          Crawler.crawl_reference(
            "https://representation.test/script",
            Map.put(classic, :crawler_ingress, :root)
          )

        assert duplicate.target_handle == classic.target_handle
      end

      assert Agent.get(calls, & &1) == 1
      assert Store.ops_count(scope) == if(status == 200, do: 1, else: 0)
      frontier = :sys.get_state(Store).scheduler.frontier
      assert map_size(frontier.jobs) == map_size(before.jobs)
      assert frontier.representation_count == before.representation_count
    end
  end

  test "a public root retries a terminal503 after the same run is fully idle", context do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    adapter = fn request ->
      attempt = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

      {request,
       Req.Response.new(
         status: if(attempt == 1, do: 503, else: 200),
         body: "recovered",
         headers: [{"content-type", "text/plain"}]
       )}
    end

    url = "https://representation.test/idle-retry"
    assert {:ok, first} = Crawler.crawl(url, options(context, adapter))

    await(fn ->
      assert %{status: :failed} = Store.target_outcome(first.target_handle)
      state = :sys.get_state(Store)
      assert state.scheduler.claims == %{}
      assert Store.pending_count(context.scope) == 0
      assert Store.inflight_count(context.scope) == 0
      assert Map.get(state.scheduler.notification_runs, {context.scope, first.generation}, 0) == 0
    end)

    assert {:ok, same_crawl} = Crawler.crawl_reference(url, first)
    assert same_crawl.target_handle == first.target_handle
    assert Agent.get(calls, & &1) == 1
    assert {:ok, retry} = Crawler.crawl(url, first)
    assert retry.generation == first.generation
    assert retry.target_handle != first.target_handle

    await(fn ->
      assert %{status: :succeeded} = Store.target_outcome(retry.target_handle)
      assert :sys.get_state(Store).scheduler.claims == %{}
    end)

    assert %{status: :failed} = Store.target_outcome(first.target_handle)
    assert Agent.get(calls, & &1) == 2
    assert Store.ops_count(context.scope) == 1
  end

  test "an opaque SVG image can be interpreted as a document from equivalent request bytes",
       context do
    %{site: site} = Crawler.ReqTestSite.open()

    Crawler.ReqTestSite.expect_once(site, "GET", "/shared.svg", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/svg+xml") |> Plug.Conn.resp(200, "<svg/>")
    end)

    opts =
      Crawler.Options.assign_defaults(%{
        scope: context.scope,
        url: site.url <> "/shared.svg",
        req_options: site.req_options,
        store: Store,
        respect_robots: false,
        html_tag: "img",
        cookie_navigation: false
      })

    assert {:ok, %{context: %{opaque?: false}}} = Crawler.Fetcher.Requester.prepare(opts)
    assert %Store.Page{} = image = Crawler.Fetcher.fetch(opts)
    assert %Store.Page{body: "<svg/>"} = document = Crawler.Fetcher.fetch(%{opts | html_tag: "a"})
    assert image.source_revision == document.source_revision
    assert Store.ops_count(context.scope) == 1
  end

  test "a custom redirect filter makes the actual ReqTestSite response private", context do
    %{site: site} = Crawler.ReqTestSite.open()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Crawler.ReqTestSite.expect(site, "GET", "/private.svg", fn conn ->
      Agent.update(calls, &(&1 + 1))
      conn |> Plug.Conn.put_resp_content_type("image/svg+xml") |> Plug.Conn.resp(200, "<svg/>")
    end)

    opts =
      Crawler.Options.assign_defaults(%{
        scope: context.scope,
        url: site.url <> "/private.svg",
        req_options: site.req_options,
        store: Store,
        respect_robots: false,
        html_tag: "img",
        cookie_navigation: false,
        url_filter: CapturingFilter,
        representation_observer: self()
      })

    assert {:ok, %{context: %{opaque?: true}}} = Crawler.Fetcher.Requester.prepare(opts)
    assert %Store.Page{} = image = Crawler.Fetcher.fetch(opts)
    state = :sys.get_state(Store)
    job = state.scheduler.frontier.jobs[image.target_handle].job

    assert %{status: :private, source: nil} =
             state.scheduler.representations[job.representation_id]

    assert %Store.Page{body: "<svg/>"} = Crawler.Fetcher.fetch(%{opts | html_tag: "a"})
    assert Agent.get(calls, & &1) == 2
    assert_receive {:filtered, "img"}
    assert_receive {:filtered, "a"}
  end

  test "a delayed variant never borrows a newer URL row's body or resource receipt", context do
    adapter = fn request ->
      body = List.first(request.headers["x-variant"])

      {request,
       Req.Response.new(status: 200, body: body, headers: [{"content-type", "text/plain"}])}
    end

    opts =
      options(context, adapter)
      |> Keyword.put(:max_body, 1_048_576)
      |> Keyword.put(:max_analysis_bytes, 4_194_304)
      |> Keyword.put(:store, HeldStore)
      |> Keyword.put(:representation_observer, self())

    first_opts =
      Keyword.update!(opts, :req_options, &Keyword.put(&1, :headers, [{"x-variant", "first"}]))

    assert {:ok, first} = Crawler.crawl("https://representation.test/overlap", first_opts)
    assert_receive {:stored_variant, "first", executor}, 1_000

    second_opts =
      Keyword.update!(opts, :req_options, &Keyword.put(&1, :headers, [{"x-variant", "second"}]))

    assert {:ok, second} = Crawler.crawl("https://representation.test/overlap", second_opts)
    await(fn -> assert %{status: :succeeded} = Store.target_outcome(second.target_handle) end)
    send(executor, :continue_variant)
    await(fn -> assert %{status: :succeeded} = Store.target_outcome(first.target_handle) end)
    assert_receive {:interpreted, :module, "first"}
    assert_receive {:interpreted, :module, "second"}
    assert Store.ops_count(context.scope) == 1
  end

  test "a late goal on the same private prepared request starts a fresh attempt", context do
    parent = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    adapter = fn request ->
      count = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
      send(parent, {:private_transport, count})

      {request,
       Req.Response.new(
         status: 200,
         body: "attempt #{count}",
         headers: [{"content-type", "text/plain"}]
       )}
    end

    opts =
      context
      |> options(adapter)
      |> Map.new()
      |> Map.merge(%{
        url: "https://representation.test/private-prepared",
        javascript_goal: :script,
        representation_observer: self()
      })
      |> Crawler.Options.assign_defaults()

    assert :ok = Crawler.QueueTickets.attach(context.queue, opts.max_queue_tickets)
    assert {:ok, prepared} = Crawler.Fetcher.Requester.prepare(opts)
    prepared = %{prepared | context: %{prepared.context | opaque?: true}}
    assert {:ok, first} = Store.admit_job(opts, prepared, :fetch)
    await(fn -> assert %{status: :succeeded} = Store.target_outcome(first.target_handle) end)

    await(fn ->
      assert :sys.get_state(Store).scheduler.claims == %{}
      assert Crawler.Frontier.Ring.size(:sys.get_state(Store).scheduler.outcomes) == 0
    end)

    assert {:ok, second} =
             Store.admit_job(Map.put(first, :javascript_goal, :module), prepared, :fetch)

    assert second.target_handle != first.target_handle
    await(fn -> assert %{status: :succeeded} = Store.target_outcome(second.target_handle) end)
    assert_receive {:private_transport, 1}
    assert_receive {:private_transport, 2}
    assert_receive {:interpreted, :script, "attempt 1"}
    assert_receive {:interpreted, :module, "attempt 2"}
    assert Agent.get(calls, & &1) == 2
    assert Store.ops_count(context.scope) == 1
    await(fn -> assert :sys.get_state(Store).scheduler.claims == %{} end)
  end

  test "pending and late contexts cannot reuse a private failed response", context do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    adapter = fn request ->
      count = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

      {request,
       Req.Response.new(
         status: if(count == 1, do: 401, else: 200),
         body: "attempt #{count}",
         headers: [{"content-type", "text/plain"}]
       )}
    end

    opts =
      context
      |> options(adapter)
      |> Map.new()
      |> Map.put(:req_options,
        finch_request: fn request, _finch, _name, _opts -> adapter.(request) end
      )
      |> Map.merge(%{
        url: "https://representation.test/private-failure",
        javascript_goal: :script,
        representation_observer: self()
      })
      |> Crawler.Options.assign_defaults()

    assert :ok = Crawler.QueueTickets.attach(context.queue, opts.max_queue_tickets)
    assert {:ok, prepared} = Crawler.Fetcher.Requester.prepare(opts)
    assert prepared.context.opaque?
    OPQ.pause(context.queue)
    assert {:paused, _, _} = OPQ.info(context.queue)
    assert {:ok, first} = Store.admit_job(opts, prepared, :fetch)

    assert {:ok, pending} =
             Store.admit_job(Map.put(first, :javascript_goal, :module), prepared, :fetch)

    OPQ.resume(context.queue)

    await(fn ->
      assert %{status: :rejected} = Store.target_outcome(first.target_handle)
      assert %{status: :succeeded} = Store.target_outcome(pending.target_handle)
      assert :sys.get_state(Store).scheduler.claims == %{}
      assert Crawler.Frontier.Ring.size(:sys.get_state(Store).scheduler.outcomes) == 0
    end)

    assert_receive {:interpreted, :module, "attempt 2"}
    assert {:ok, late} = Store.admit_job(Map.put(first, :html_tag, "img"), prepared, :fetch)
    await(fn -> assert %{status: :succeeded} = Store.target_outcome(late.target_handle) end)
    assert Agent.get(calls, & &1) == 3
    assert %{status: :rejected} = Store.target_outcome(first.target_handle)
    assert Store.ops_count(context.scope) == 1
    await(fn -> assert :sys.get_state(Store).scheduler.claims == %{} end)
  end

  test "a cookie change only on the future redirect path requires a fresh representation",
       context do
    generation = Store.generation(context.scope)

    Store.save_cookies(
      context.scope,
      "https://representation.test/private",
      ["id=A; Path=/private; Secure"],
      generation
    )

    {:ok, calls} = Agent.start_link(fn -> [] end)

    adapter = fn request ->
      path = request.url.path
      cookie = List.first(request.headers["cookie"] || [])
      Agent.update(calls, &[{path, cookie} | &1])

      response =
        if path == "/start" do
          Req.Response.new(status: 302, headers: [{"location", "/private"}], body: "")
        else
          Req.Response.new(
            status: 200,
            headers: [{"content-type", "text/plain"}],
            body: cookie || "empty"
          )
        end

      {request, response}
    end

    opts = options(context, adapter)

    {:ok, first} =
      Crawler.crawl(
        "https://representation.test/start",
        Keyword.put(opts, :javascript_goal, :script)
      )

    await(fn -> assert %{status: :succeeded} = Store.target_outcome(first.target_handle) end)

    Store.save_cookies(
      context.scope,
      "https://representation.test/private",
      ["id=B; Path=/private; Secure"],
      generation
    )

    {:ok, second} =
      Crawler.crawl(
        "https://representation.test/start",
        Keyword.put(opts, :javascript_goal, :module)
      )

    await(fn -> assert %{status: :succeeded} = Store.target_outcome(second.target_handle) end)
    calls = Enum.reverse(Agent.get(calls, & &1))
    assert calls == [{"/start", nil}, {"/private", "id=A"}, {"/start", nil}, {"/private", "id=B"}]
    assert Store.ops_count(context.scope) == 1
  end

  test "a queued terminal replay validates redirect cookie expiry before settling", context do
    generation = Store.generation(context.scope)

    assert :ok =
             Store.save_cookies(
               context.scope,
               "https://representation.test/private",
               ["id=A; Path=/private; Secure; Max-Age=2"],
               generation
             )

    {:ok, calls} = Agent.start_link(fn -> [] end)

    adapter = fn request ->
      cookie = List.first(request.headers["cookie"] || [])
      Agent.update(calls, &[{request.url.path, cookie} | &1])

      response =
        if request.url.path == "/expiry-start" do
          Req.Response.new(status: 302, headers: [{"location", "/private"}], body: "")
        else
          Req.Response.new(
            status: if(cookie, do: 401, else: 200),
            body: cookie || "expired",
            headers: [{"content-type", "text/plain"}]
          )
        end

      {request, response}
    end

    opts =
      context
      |> options(adapter)
      |> Map.new()
      |> Map.merge(%{
        url: "https://representation.test/expiry-start",
        javascript_goal: :script,
        representation_observer: self()
      })
      |> Crawler.Options.assign_defaults()

    assert :ok = Crawler.QueueTickets.attach(context.queue, opts.max_queue_tickets)
    assert {:ok, prepared} = Crawler.Fetcher.Requester.prepare(opts)
    assert {:ok, first} = Store.admit_job(opts, prepared, :fetch)
    await(fn -> assert %{status: :rejected} = Store.target_outcome(first.target_handle) end)
    OPQ.pause(context.queue)
    assert {:paused, _, _} = OPQ.info(context.queue)

    assert {:ok, late} =
             Store.admit_job(Map.put(first, :javascript_goal, :module), prepared, :fetch)

    assert Store.target_outcome(late.target_handle) == nil
    Process.sleep(2_100)
    OPQ.resume(context.queue)
    await(fn -> assert %{status: :succeeded} = Store.target_outcome(late.target_handle) end)
    assert_receive {:interpreted, :module, "expired"}

    assert Agent.get(calls, &Enum.reverse/1) == [
             {"/expiry-start", nil},
             {"/private", "id=A"},
             {"/expiry-start", nil},
             {"/private", nil}
           ]

    assert %{status: :rejected} = Store.target_outcome(first.target_handle)
    await(fn -> assert :sys.get_state(Store).scheduler.claims == %{} end)
  end

  for ceiling <- [:service, :caller] do
    test "a private redirect fork respects the #{ceiling} representation ceiling", context do
      ceiling = unquote(ceiling)
      generation = Store.generation(context.scope)
      run = {context.scope, generation}
      before = :sys.get_state(Store).scheduler.frontier
      assert run_representations(before, run) == %{}
      old_limit = before.limits.max_representations
      service_limit = map_size(before.representations) + 1
      assert service_limit <= old_limit

      if ceiling == :service do
        :sys.replace_state(Store, fn state ->
          frontier = state.scheduler.frontier

          %{
            state
            | scheduler: %{
                state.scheduler
                | frontier: %{
                    frontier
                    | limits: Map.put(frontier.limits, :max_representations, service_limit)
                  }
              }
          }
        end)

        on_exit(fn ->
          :sys.replace_state(Store, fn state ->
            frontier = state.scheduler.frontier

            %{
              state
              | scheduler: %{
                  state.scheduler
                  | frontier: %{
                      frontier
                      | limits: Map.put(frontier.limits, :max_representations, old_limit)
                    }
                }
            }
          end)
        end)
      end

      parent = self()
      generation = Store.generation(context.scope)

      assert :ok =
               Store.save_cookies(
                 context.scope,
                 "https://representation.test/private",
                 ["id=A; Path=/private; Secure"],
                 generation
               )

      {:ok, calls} = Agent.start_link(fn -> 0 end)

      adapter = fn request ->
        if request.url.path == "/cap-start" do
          Agent.update(calls, &(&1 + 1))
          send(parent, {:cap_transport, self()})

          receive do
            :continue_cap -> :ok
          end

          {request, Req.Response.new(status: 302, headers: [{"location", "/private"}], body: "")}
        else
          {request,
           Req.Response.new(status: 200, body: "ok", headers: [{"content-type", "text/plain"}])}
        end
      end

      opts = Keyword.put(options(context, adapter), :max_representations, 1)
      OPQ.pause(context.queue)
      assert {:paused, _, _} = OPQ.info(context.queue)

      assert {:ok, first} =
               Crawler.crawl(
                 "https://representation.test/cap-start",
                 Keyword.put(opts, :javascript_goal, :script)
               )

      assert {:ok, waiting} =
               Crawler.crawl(
                 "https://representation.test/cap-start",
                 Keyword.put(opts, :javascript_goal, :module)
               )

      OPQ.resume(context.queue)
      assert_receive {:cap_transport, executor}, 1_000

      assert :ok =
               Store.save_cookies(
                 context.scope,
                 "https://representation.test/private",
                 ["id=B; Path=/private; Secure"],
                 generation
               )

      send(executor, :continue_cap)

      await(fn ->
        assert %{status: :succeeded} = Store.target_outcome(first.target_handle)

        assert %{status: :limited, reason: {:limit, :max_representations}} =
                 Store.target_outcome(waiting.target_handle)

        state = :sys.get_state(Store)
        representations = run_representations(state.scheduler.frontier, run)
        assert map_size(representations) == 1
        [representation] = Map.values(representations)

        assert state.scheduler.frontier.jobs[first.target_handle].job.representation_id ==
                 representation

        assert state.scheduler.representations[representation].owner == first.target_handle
        assert state.scheduler.claims == %{}
        assert state.scopes[context.scope].reported_limit == {:limit, :max_representations}
        assert Store.pending_count(context.scope) == 0
      end)

      assert Agent.get(calls, & &1) == 1
      assert Store.ops_count(context.scope) == 1
    end
  end

  for first_status <- [200, 401] do
    test "private redirect completion #{first_status} forks a bounded waiter with its target unchanged",
         context do
      first_status = unquote(first_status)
      parent = self()
      generation = Store.generation(context.scope)

      Store.save_cookies(
        context.scope,
        "https://representation.test/private",
        ["id=A; Path=/private; Secure"],
        generation
      )

      {:ok, calls} = Agent.start_link(fn -> 0 end)

      adapter = fn request ->
        if request.url.path == "/start" do
          count = Agent.get_and_update(calls, &{&1, &1 + 1})

          if count == 0 do
            send(parent, {:initial_transport, self()})

            receive do
              :continue -> :ok
            end
          end

          {request, Req.Response.new(status: 302, headers: [{"location", "/private"}], body: "")}
        else
          {request,
           Req.Response.new(
             status: if(Agent.get(calls, & &1) == 1, do: first_status, else: 200),
             body: List.first(request.headers["cookie"] || []) || "empty",
             headers: [{"content-type", "text/plain"}]
           )}
        end
      end

      opts = Keyword.put(options(context, adapter), :representation_observer, self())
      OPQ.pause(context.queue)
      assert {:paused, _, _} = OPQ.info(context.queue)

      {:ok, first} =
        Crawler.crawl(
          "https://representation.test/start",
          Keyword.put(opts, :javascript_goal, :script)
        )

      {:ok, waiting} =
        Crawler.crawl(
          "https://representation.test/start",
          Keyword.put(opts, :javascript_goal, :module)
        )

      OPQ.resume(context.queue)
      assert_receive {:initial_transport, executor}, 1_000

      Store.save_cookies(
        context.scope,
        "https://representation.test/private",
        ["id=B; Path=/private; Secure"],
        generation
      )

      send(executor, :continue)

      await(fn ->
        assert %{status: first_outcome} = Store.target_outcome(first.target_handle)
        assert first_outcome == if(first_status == 200, do: :succeeded, else: :rejected)
        assert %{status: :succeeded} = Store.target_outcome(waiting.target_handle)
      end)

      assert Agent.get(calls, & &1) == 2
      if first_status == 200, do: assert_receive({:interpreted, :script, "id=B"})
      assert_receive {:interpreted, :module, "id=B"}

      await(fn ->
        state = :sys.get_state(Store)
        assert state.scheduler.claims == %{}
        assert Crawler.Frontier.Ring.size(state.scheduler.forks) == 0
        assert Crawler.Frontier.Ring.size(state.scheduler.outcomes) == 0

        assert Crawler.Frontier.Ring.size(
                 state.scheduler.run_representations[{context.scope, generation}]
               ) <= 2
      end)

      assert Store.ops_count(context.scope) == 1
    end
  end

  for reverse? <- [false, true] do
    test "credentials, headers and cookie partitions remain distinct, reverse=#{reverse?}",
         context do
      generation = Store.generation(context.scope)
      url = "https://representation.test/partitioned"

      for {site, value} <- [{"https://first.test", "one"}, {"https://second.test", "two"}] do
        assert :ok =
                 Store.save_cookies(
                   context.scope,
                   url,
                   ["id=#{value}; Secure; SameSite=None; Partitioned; Path=/"],
                   generation,
                   %{site: site, credentials: :include}
                 )
      end

      parent = self()

      adapter = fn request ->
        body =
          Enum.join(request.headers["x-variant"] || [], ",") <>
            "|" <> Enum.join(request.headers["cookie"] || [], ",")

        send(parent, {:variant_transport, body})

        {request,
         Req.Response.new(status: 200, body: body, headers: [{"content-type", "text/plain"}])}
      end

      variants = [
        {"https://first.test", :include, "same", "same|id=one"},
        {"https://second.test", :include, "same", "same|id=two"},
        {"https://first.test", :omit, "other", "other|"}
      ]

      variants = if unquote(reverse?), do: Enum.reverse(variants), else: variants

      for {site, credentials, header, expected} <- variants do
        opts =
          options(context, adapter)
          |> Keyword.put(:cookie_site, site)
          |> Keyword.put(:credentials, credentials)
          |> Keyword.put(:representation_observer, self())
          |> Keyword.update!(:req_options, &Keyword.put(&1, :headers, [{"x-variant", header}]))

        assert {:ok, target} = Crawler.crawl(url, opts)
        await(fn -> assert %{status: :succeeded} = Store.target_outcome(target.target_handle) end)
        assert_receive {:variant_transport, ^expected}
        assert_receive {:interpreted, :module, ^expected}
      end

      assert Store.ops_count(context.scope) == 1
      await(fn -> assert :sys.get_state(Store).scheduler.claims == %{} end)

      assert Crawler.Frontier.Ring.size(
               :sys.get_state(Store).scheduler.run_representations[{context.scope, generation}]
             ) == 3
    end
  end

  test "a permanently page-limited owner yields to its eligible response waiter", context do
    parent = self()

    adapter = fn request ->
      if request.url.path == "/held-first" do
        send(parent, {:held_first_transport, self()})

        receive do
          :release_first -> :ok
        end
      end

      send(parent, {:lifecycle_transport, request.url.path})

      {request,
       Req.Response.new(
         status: 200,
         body: request.url.path,
         headers: [{"content-type", "text/plain"}]
       )}
    end

    opts = Keyword.put(options(context, adapter), :representation_observer, self())

    assert {:ok, y} =
             Crawler.crawl(
               "https://representation.test/held-first",
               Keyword.put(opts, :max_pages, 1)
             )

    assert_receive {:held_first_transport, executor}, 1_000

    assert {:ok, owner} =
             Crawler.crawl(
               "https://representation.test/after-first",
               opts ++ [max_pages: 1, javascript_goal: :script]
             )

    assert {:ok, waiter} =
             Crawler.crawl(
               "https://representation.test/after-first",
               opts ++ [max_pages: 2, javascript_goal: :module]
             )

    state = :sys.get_state(Store)
    representation = state.scheduler.frontier.jobs[owner.target_handle].job.representation_id

    assert state.scheduler.frontier.jobs[waiter.target_handle].job.representation_id ==
             representation

    send(executor, :release_first)

    await(fn ->
      assert %{status: :succeeded} = Store.target_outcome(y.target_handle)

      assert %{status: :limited, reason: {:limit, :max_pages}} =
               Store.target_outcome(owner.target_handle)

      assert %{status: :succeeded} = Store.target_outcome(waiter.target_handle)
      assert :sys.get_state(Store).scheduler.claims == %{}
    end)

    assert_receive {:lifecycle_transport, "/held-first"}
    assert_receive {:lifecycle_transport, "/after-first"}
    refute_receive {:lifecycle_transport, _}, 20
    assert_receive {:interpreted, :module, "/after-first"}
    refute_receive {:interpreted, :script, "/after-first"}, 20
    assert Store.ops_count(context.scope) == 2
    state = :sys.get_state(Store)
    assert state.scheduler.representations[representation].owner == waiter.target_handle
    assert state.scheduler.frontier.runs[{context.scope, y.generation}].representation_count == 2
    assert Crawler.Frontier.Ring.size(state.scheduler.forks) == 0
  end

  test "retiring a paused owner queue keeps its live sibling's one-response attempt", context do
    {:links, previous} = Process.info(self(), :links)
    {:ok, sibling} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 1, timeout: 5_000)
    {:links, current} = Process.info(self(), :links)
    children = current -- previous
    Enum.each(children, &Process.unlink/1)

    on_exit(fn ->
      Enum.each(children, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    end)

    OPQ.pause(context.queue)
    OPQ.pause(sibling)
    assert {:paused, _, _} = OPQ.info(context.queue)
    assert {:paused, _, _} = OPQ.info(sibling)
    parent = self()

    adapter = fn request ->
      send(parent, :sibling_transport)

      {request,
       Req.Response.new(status: 200, body: "sibling", headers: [{"content-type", "text/plain"}])}
    end

    opts = options(context, adapter) ++ [max_representations: 1, representation_observer: self()]

    assert {:ok, owner} =
             Crawler.crawl(
               "https://representation.test/retired-owner",
               opts ++ [javascript_goal: :script]
             )

    assert {:ok, waiter} =
             Crawler.crawl(
               "https://representation.test/retired-owner",
               opts ++ [queue: sibling, javascript_goal: :module]
             )

    assert owner.generation == waiter.generation
    state = :sys.get_state(Store)
    representation = state.scheduler.frontier.jobs[owner.target_handle].job.representation_id

    assert state.scheduler.frontier.jobs[waiter.target_handle].job.representation_id ==
             representation

    assert :ok = Store.release_queue(context.queue)

    await(fn ->
      assert %{status: :cancelled, reason: :queue_retired} =
               Store.target_outcome(owner.target_handle)
    end)

    assert Store.target_outcome(waiter.target_handle) == nil
    OPQ.resume(sibling)

    await(fn ->
      assert %{status: :succeeded} = Store.target_outcome(waiter.target_handle)
      assert :sys.get_state(Store).scheduler.claims == %{}
    end)

    assert_receive :sibling_transport
    refute_receive :sibling_transport, 20
    assert_receive {:interpreted, :module, "sibling"}
    assert Store.ops_count(context.scope) == 1
    state = :sys.get_state(Store)

    assert state.scheduler.frontier.runs[{context.scope, waiter.generation}].representation_count ==
             1

    assert state.scheduler.representations[representation].owner == waiter.target_handle
    assert Crawler.Frontier.Ring.size(state.scheduler.forks) == 0
  end

  for killed <- [:executor, :worker] do
    test "an earlier503 cannot turn a killed #{killed}'s retry backoff into terminal replay",
         context do
      parent = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      adapter = fn request ->
        attempt = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
        send(parent, {:backoff_transport, attempt})

        {request,
         Req.Response.new(
           status: if(attempt == 1, do: 503, else: 200),
           body: "recovered",
           headers: [{"content-type", "text/plain"}]
         )}
      end

      opts =
        options(context, adapter)
        |> Keyword.merge(
          retrier: BackoffRetrier,
          retries: 1,
          max_representations: 2,
          cookie_navigation: false,
          credentials: :omit,
          representation_observer: self()
        )
        |> Keyword.update!(:req_options, &Keyword.put(&1, :retry, false))

      OPQ.pause(context.queue)
      assert {:paused, _, _} = OPQ.info(context.queue)

      assert {:ok, owner} =
               Crawler.crawl(
                 "https://representation.test/killed-backoff",
                 opts ++ [javascript_goal: :script]
               )

      assert {:ok, waiter} =
               Crawler.crawl(
                 "https://representation.test/killed-backoff",
                 opts ++ [javascript_goal: :module]
               )

      Code.ensure_loaded!(:timer)
      assert :erlang.trace_pattern({:timer, :sleep, 1}, true, []) == 1
      on_exit(fn -> :erlang.trace_pattern({:timer, :sleep, 1}, false, []) end)
      OPQ.resume(context.queue)
      assert_receive {:retry_result, executor, target}, 1_000
      assert target == owner.target_handle
      assert :erlang.trace(executor, true, [:call]) == 1
      send(executor, :enter_backoff)
      assert_receive {:trace, ^executor, :call, {:timer, :sleep, [60_000]}}, 1_000
      state = :sys.get_state(Store)
      {:running, claim} = state.scheduler.frontier.jobs[target].status

      assert %{status: :failed} =
               state.scheduler.representations[
                 state.scheduler.frontier.jobs[target].job.representation_id
               ].terminal_outcome

      victim =
        if unquote(killed) == :executor, do: executor, else: state.scheduler_workers[claim].worker

      Process.exit(victim, :kill)
      :erlang.trace_pattern({:timer, :sleep, 1}, false, [])

      await(fn ->
        assert %{status: :failed} = Store.target_outcome(owner.target_handle)
        assert %{status: :succeeded} = Store.target_outcome(waiter.target_handle)
        assert :sys.get_state(Store).scheduler.claims == %{}
      end)

      assert {:ok, late} =
               Crawler.crawl(
                 "https://representation.test/killed-backoff",
                 opts ++ [javascript_goal: :module, html_tag: "img"]
               )

      await(fn -> assert %{status: :succeeded} = Store.target_outcome(late.target_handle) end)
      assert_receive {:backoff_transport, 1}
      assert_receive {:backoff_transport, 2}
      refute_receive {:backoff_transport, _}, 20
      assert Agent.get(calls, & &1) == 2
      assert Store.ops_count(context.scope) == 1
      state = :sys.get_state(Store)

      assert state.scheduler.frontier.runs[{context.scope, owner.generation}].representation_count ==
               2

      assert state.scheduler.frontier.jobs[waiter.target_handle].job.id == waiter.target_handle
      assert Crawler.Frontier.Ring.size(state.scheduler.forks) == 0
    end
  end

  for failure <- [:error, :throw, :exit] do
    test "a direct retrier #{failure} keeps its earlier response private to its own outcome",
         context do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      adapter = fn request ->
        attempt = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

        {request,
         Req.Response.new(
           status: if(attempt == 1, do: 503, else: 200),
           body: "recovered",
           headers: [{"content-type", "text/plain"}]
         )}
      end

      opts =
        options(context, adapter)
        |> Keyword.merge(
          retrier: LocalFailureRetrier,
          failure_kind: unquote(failure),
          max_representations: 2,
          cookie_navigation: false,
          credentials: :omit,
          representation_observer: self()
        )
        |> Keyword.update!(:req_options, &Keyword.put(&1, :retry, false))

      OPQ.pause(context.queue)
      assert {:paused, _, _} = OPQ.info(context.queue)

      direct =
        opts
        |> Map.new()
        |> Map.merge(%{url: "https://representation.test/local-failure", javascript_goal: :script})

      task = Task.async(fn -> Crawler.crawl_now(direct) end)
      assert_receive {:local_result, executor, owner}, 1_000
      assert {:ok, waiter} = Crawler.crawl(direct.url, opts ++ [javascript_goal: :module])
      send(executor, :fail_locally)
      assert {:error, {unquote(failure), _}} = Task.await(task)
      assert %{status: :failed} = Store.target_outcome(owner)
      OPQ.resume(context.queue)

      await(fn ->
        assert %{status: :succeeded} = Store.target_outcome(waiter.target_handle)
        assert :sys.get_state(Store).scheduler.claims == %{}
      end)

      assert Agent.get(calls, & &1) == 2
      assert Store.ops_count(context.scope) == 1
    end
  end

  defp run_representations(frontier, run) do
    Map.filter(frontier.representations, fn {{owner, _key}, _id} -> owner == run end)
  end

  defp options(context, adapter) do
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      request =
        Req.new(
          url: %URI{
            scheme: Atom.to_string(conn.scheme),
            host: conn.host,
            port: conn.port,
            path: conn.request_path,
            query: conn.query_string
          },
          headers: conn.req_headers
        )

      {_request, response} = adapter.(request)
      conn = %{conn | resp_headers: Req.get_headers_list(response)}
      Plug.Conn.send_resp(conn, response.status, response.body || "")
    end)

    [
      scope: context.scope,
      queue: context.queue,
      parser: Parser,
      store: Store,
      respect_robots: false,
      retries: 0,
      html_tag: "script",
      req_options: [plug: {Req.Test, name}]
    ]
  end

  defp await(check, attempts \\ 300)

  defp await(check, attempts) when attempts > 0 do
    try do
      check.()
    rescue
      ExUnit.AssertionError ->
        receive do
        after
          5 -> :ok
        end

        await(check, attempts - 1)
    end
  end

  defp await(check, 0), do: check.()
end
