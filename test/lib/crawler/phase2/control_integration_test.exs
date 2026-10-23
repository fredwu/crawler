defmodule Crawler.Phase2.ControlIntegrationTest do
  use ExUnit.Case, async: false
  alias Crawler.Store

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    scope = make_ref()
    {:links, before_links} = Process.info(self(), :links)
    {:ok, queue} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 1, timeout: 5_000)
    {:links, after_links} = Process.info(self(), :links)
    children = after_links -- before_links
    Enum.each(children, &Process.unlink/1)

    on_exit(fn ->
      Store.dispose_scope(scope)
      Enum.each(children, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    end)

    %{scope: scope, queue: queue}
  end

  test "queued controls preserve distinct headers, credentials and cookie partitions before preparation",
       context do
    parent = self()
    generation = Store.generation(context.scope)
    url = "https://control.test/partitioned"

    for {site, value} <- [{"https://one.test", "one"}, {"https://two.test", "two"}] do
      assert :ok =
               Store.save_cookies(
                 context.scope,
                 url,
                 ["id=#{value}; Secure; SameSite=None; Partitioned; Path=/"],
                 generation,
                 %{site: site, credentials: :include}
               )
    end

    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      send(
        parent,
        {:control_variant, Plug.Conn.get_req_header(conn, "x-variant"),
         Plug.Conn.get_req_header(conn, "cookie")}
      )

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/xml")
      |> Plug.Conn.send_resp(200, "<urlset/>")
    end)

    OPQ.pause(context.queue)
    assert {:paused, _, _} = OPQ.info(context.queue)

    handles =
      for {site, credentials, header} <- [
            {"https://one.test", :include, "A"},
            {"https://two.test", :include, "B"},
            {"https://one.test", :omit, "C"}
          ] do
        assert {:ok, opts} =
                 Crawler.QueueHandler.enqueue_control(
                   url,
                   Map.merge(context, %{
                     generation: generation,
                     respect_robots: false,
                     retries: 0,
                     credentials: credentials,
                     cookie_site: site,
                     req_options: [plug: {Req.Test, name}, headers: [{"x-variant", header}]]
                   })
                 )

        opts.target_handle
      end

    assert length(Enum.uniq(handles)) == 3

    for handle <- handles,
        do:
          assert(
            :sys.get_state(Store).scheduler.frontier.jobs[handle].job.prepared_request == nil
          )

    refute_receive {:control_variant, _, _}, 10
    OPQ.resume(context.queue)

    for {header, cookie} <- [{"A", ["id=one"]}, {"B", ["id=two"]}, {"C", []}] do
      assert_receive {:control_variant, [^header], ^cookie}, 1_000
    end

    await(fn ->
      for handle <- handles, do: assert(%{status: :succeeded} = Store.target_outcome(handle))
      assert :sys.get_state(Store).scheduler.claims == %{}
      assert Store.pending_count(context.scope) == 0
    end)
  end

  test "identical queued callback terms retain separate unfrozen command ownership", context do
    parent = self()
    {:ok, session} = Agent.start_link(fn -> ["A", "B"] end)

    adapter = fn request ->
      token = Agent.get_and_update(session, fn [token | rest] -> {token, rest} end)
      send(parent, {:deferred_control_session, token})

      {request,
       Req.Response.new(
         status: 200,
         body: "<urlset><!--#{token}--></urlset>",
         headers: [{"content-type", "application/xml"}]
       )}
    end

    opts =
      Map.merge(context, %{
        respect_robots: false,
        retries: 0,
        req_options: [adapter: adapter]
      })

    OPQ.pause(context.queue)
    assert {:paused, _, _} = OPQ.info(context.queue)
    assert {:ok, first} = Crawler.QueueHandler.enqueue_control("https://control.test/live", opts)
    assert {:ok, second} = Crawler.QueueHandler.enqueue_control("https://control.test/live", opts)
    refute first.target_handle == second.target_handle
    refute_receive {:deferred_control_session, _}, 10
    OPQ.resume(context.queue)
    assert_receive {:deferred_control_session, "A"}, 1_000
    assert_receive {:deferred_control_session, "B"}, 1_000

    await(fn ->
      assert %{status: :succeeded} = Store.target_outcome(first.target_handle)
      assert %{status: :succeeded} = Store.target_outcome(second.target_handle)
      state = :sys.get_state(Store)
      first_job = state.scheduler.frontier.jobs[first.target_handle].job
      second_job = state.scheduler.frontier.jobs[second.target_handle].job
      refute first_job.representation_id == second_job.representation_id

      assert %{status: :private, source: nil} =
               state.scheduler.representations[first_job.representation_id]

      assert %{status: :private, source: nil} =
               state.scheduler.representations[second_job.representation_id]

      assert state.scheduler.claims == %{}
      assert Store.pending_count(context.scope) == 0
    end)
  end

  test "a shallower control interpretation reuses frozen bytes and discovers its eligible child",
       context do
    parent = self()
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      send(parent, {:depth_control, conn.request_path})

      body =
        if conn.request_path == "/root",
          do: "<sitemapindex><sitemap><loc>/child</loc></sitemap></sitemapindex>",
          else: "<urlset/>"

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/xml")
      |> Plug.Conn.send_resp(200, body)
    end)

    opts =
      Map.merge(context, %{
        respect_robots: false,
        retries: 0,
        max_control_depth: 1,
        req_options: [plug: {Req.Test, name}]
      })

    OPQ.pause(context.queue)
    assert {:paused, _, _} = OPQ.info(context.queue)

    assert {:ok, deep} =
             Crawler.QueueHandler.enqueue_control(
               "https://control.test/root",
               Map.put(opts, :control_depth, 1)
             )

    assert {:ok, shallow} =
             Crawler.QueueHandler.enqueue_control(
               "https://control.test/root",
               Map.put(opts, :control_depth, 0)
             )

    assert deep.target_handle != shallow.target_handle
    OPQ.resume(context.queue)
    assert_receive {:depth_control, "/root"}, 1_000
    assert_receive {:depth_control, "/child"}, 1_000

    await(fn ->
      assert %{status: :limited, reason: {:limit, :max_control_depth}} =
               Store.target_outcome(deep.target_handle)

      assert %{status: :succeeded} = Store.target_outcome(shallow.target_handle)
      assert Store.pending_count(context.scope) == 0
      assert :sys.get_state(Store).scheduler.claims == %{}
    end)

    refute_receive {:depth_control, "/root"}, 20
  end

  test "global defaults are frozen independently after both commands were queued", context do
    parent = self()
    previous = Application.get_env(:req, :default_options, :missing)

    on_exit(fn ->
      if previous == :missing,
        do: Application.delete_env(:req, :default_options),
        else: Application.put_env(:req, :default_options, previous)
    end)

    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      send(parent, {:global_control_auth, Plug.Conn.get_req_header(conn, "authorization")})
      Plug.Conn.send_resp(conn, 200, "<urlset/>")
    end)

    opts =
      Map.merge(context, %{
        respect_robots: false,
        retries: 0,
        req_options: [plug: {Req.Test, name}]
      })

    OPQ.pause(context.queue)
    assert {:paused, _, _} = OPQ.info(context.queue)
    Application.put_env(:req, :default_options, auth: {:bearer, "A"})

    assert {:ok, first} =
             Crawler.QueueHandler.enqueue_control("https://control.test/defaults", opts)

    assert {:ok, second} =
             Crawler.QueueHandler.enqueue_control("https://control.test/defaults", opts)

    refute first.target_handle == second.target_handle
    Application.put_env(:req, :default_options, auth: {:bearer, "B"})
    OPQ.resume(context.queue)
    assert_receive {:global_control_auth, ["Bearer B"]}, 1_000

    await(fn ->
      assert %{status: :succeeded} = Store.target_outcome(first.target_handle)
      assert %{status: :succeeded} = Store.target_outcome(second.target_handle)
      state = :sys.get_state(Store)

      first_job = state.scheduler.frontier.jobs[first.target_handle].job
      second_job = state.scheduler.frontier.jobs[second.target_handle].job
      assert first_job.representation_id == second_job.representation_id
      assert state.scheduler.claims == %{}
    end)

    refute_receive {:global_control_auth, _}, 20
  end

  test "provisional controls do not consume frozen representation capacity", context do
    parent = self()
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      send(parent, {:capped_control, Plug.Conn.get_req_header(conn, "x-variant")})
      Plug.Conn.send_resp(conn, 200, "<urlset/>")
    end)

    opts =
      Map.merge(context, %{
        max_representations: 1,
        respect_robots: false,
        retries: 0,
        req_options: [plug: {Req.Test, name}]
      })

    url = "https://control.test/capped"
    assert {:ok, first} = Crawler.QueueHandler.enqueue_control(url, opts)
    assert_receive {:capped_control, []}, 1_000
    await(fn -> assert %{status: :succeeded} = Store.target_outcome(first.target_handle) end)

    OPQ.pause(context.queue)
    assert {:paused, _, _} = OPQ.info(context.queue)
    assert {:ok, replay} = Crawler.QueueHandler.enqueue_control(url, opts)

    assert {:ok, changed} =
             Crawler.QueueHandler.enqueue_control(
               url,
               Map.put(opts, :req_options,
                 plug: {Req.Test, name},
                 headers: [{"x-variant", "new"}]
               )
             )

    state = :sys.get_state(Store)

    assert state.scheduler.frontier.runs[{context.scope, first.generation}].representation_count ==
             1

    key = {context.scope, first.generation}

    assert Enum.count(state.scheduler.frontier.representations, fn {{run, _}, _} -> run == key end) ==
             3

    OPQ.resume(context.queue)

    await(fn ->
      assert %{status: :succeeded} = Store.target_outcome(replay.target_handle)

      assert %{status: :limited, reason: {:limit, :max_representations}} =
               Store.target_outcome(changed.target_handle)

      state = :sys.get_state(Store)

      assert state.scheduler.frontier.runs[{context.scope, first.generation}].representation_count ==
               1

      assert state.scheduler.claims == %{}
      assert Store.pending_count(context.scope) == 0
    end)

    refute_receive {:capped_control, _}, 20
  end

  test "a single control freezes in place under a one-representation caller cap", context do
    parent = self()
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      send(parent, :single_control_transport)
      Plug.Conn.send_resp(conn, 200, "<urlset/>")
    end)

    assert {:ok, opts} =
             Crawler.QueueHandler.enqueue_control(
               "https://control.test/one",
               Map.merge(context, %{
                 max_representations: 1,
                 respect_robots: false,
                 retries: 0,
                 req_options: [plug: {Req.Test, name}]
               })
             )

    assert_receive :single_control_transport, 1_000

    await(fn ->
      assert %{status: :succeeded} = Store.target_outcome(opts.target_handle)
      state = :sys.get_state(Store)

      assert state.scheduler.frontier.runs[{context.scope, opts.generation}].representation_count ==
               1

      assert Crawler.Frontier.Ring.size(
               state.scheduler.run_representations[{context.scope, opts.generation}]
             ) == 1

      assert state.scopes[context.scope].control_documents == 1
      assert state.scopes[context.scope].control_bytes == 9
      assert state.scheduler.claims == %{}
    end)

    refute_receive :single_control_transport, 20
  end

  test "a page-free sitemap graph terminates with an explicit bounded limit", context do
    parent = self()

    adapter = fn request ->
      index = request.url.path |> String.trim_leading("/") |> String.to_integer()
      send(parent, {:control_request, index})

      body =
        "<sitemapindex><sitemap><loc>https://control.test/#{index + 1}</loc></sitemap></sitemapindex>"

      {request,
       Req.Response.new(status: 200, body: body, headers: [{"content-type", "application/xml"}])}
    end

    assert {:ok, root} =
             Crawler.QueueHandler.enqueue_control(
               "https://control.test/0",
               Map.merge(context, %{
                 respect_robots: false,
                 retries: 0,
                 max_control_documents: 3,
                 req_options: [adapter: adapter]
               })
             )

    for index <- 0..2, do: assert_receive({:control_request, ^index}, 1_000)

    await(fn ->
      state = :sys.get_state(Store)
      assert Store.pending_count(context.scope) == 0
      assert state.scheduler.claims == %{}
      assert %{reported_limit: {:limit, :max_control_documents}} = state.scopes[context.scope]

      outcomes =
        for {_id, %{job: %{authority: {scope, _, _}}, outcome: outcome}} <-
              state.scheduler.frontier.jobs,
            scope == context.scope,
            do: outcome

      assert length(outcomes) == 3

      assert Enum.count(
               outcomes,
               &match?(%{status: :limited, reason: {:limit, :max_control_documents}}, &1)
             ) == 1
    end)

    assert %{status: :succeeded} = Store.target_outcome(root.target_handle)
    assert Store.ops_count(context.scope) == 0
    refute_receive {:control_request, 3}, 20
  end

  test "an expiring control settles its target and releases its execution claim", context do
    parent = self()

    adapter = fn _request ->
      send(parent, :control_held)

      receive do
        :never -> :ok
      end
    end

    assert {:ok, root} =
             Crawler.QueueHandler.enqueue_control(
               "https://control.test/held",
               Map.merge(context, %{
                 respect_robots: false,
                 retries: 0,
                 attempt_timeout: 75,
                 req_options: [adapter: adapter]
               })
             )

    assert_receive :control_held

    await(fn ->
      state = :sys.get_state(Store)

      assert %{status: :limited, reason: {:deadline, :attempt}} =
               Store.target_outcome(root.target_handle)

      assert Store.pending_count(context.scope) == 0
      assert state.scheduler.claims == %{}
      assert state.execution_claims == %{}
    end)

    assert Process.alive?(context.queue)
  end

  test "control document accounting distinguishes inline roles and repeats once" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)

    assert :ok =
             Crawler.Store.Execution.run(
               %{scope: scope, url: "https://control.test/feed", max_control_documents: 2},
               fn opts ->
                 assert :ok = Store.account_control_document(opts)
                 assert :ok = Store.account_control_document(opts)

                 robots =
                   Map.put(%{opts | url: "https://control.test/robots.txt"}, :robots_fetch, true)

                 assert :ok = Store.account_control_document(robots)

                 assert {:error, {:limit, :max_control_documents}} =
                          Store.account_control_document(%{
                            opts
                            | url: "https://control.test/other"
                          })

                 :ok
               end
             )

    assert :sys.get_state(Store).scopes[scope].control_documents == 2
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
