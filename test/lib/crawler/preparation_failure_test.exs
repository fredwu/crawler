defmodule Crawler.PreparationFailureTest do
  use ExUnit.Case, async: false

  alias Crawler.Queue
  alias Crawler.QueueTickets
  alias Crawler.Store

  defmodule FailingModifier do
    def opts(opts) do
      send(opts.failure_owner, {
        :modifier_preparation,
        opts.failure_id,
        self(),
        opts[:queue_owner],
        opts[:queue]
      })

      if opts[:hold_preparation] do
        receive do
          :release_preparation -> :ok
        end
      end

      reason = {:modifier_payload, :binary.copy("m", opts.failure_bytes)}

      case opts.failure_kind do
        :throw -> throw(reason)
        :exit -> exit(reason)
      end
    end

    def headers(_opts), do: []
  end

  defmodule ObservedModifier do
    def opts(opts) do
      if String.contains?(opts.url, "/child-") do
        lease = Process.get(:crawler_execution_lease)
        execution = :sys.get_state(Store).executions[lease]

        send(opts.failure_owner, {
          :child_preparation,
          self(),
          lease,
          if(execution, do: execution.deadline)
        })
      end

      []
    end

    def headers(_opts), do: []
  end

  for entry <- [:direct, :async], kind <- [:throw, :exit] do
    test "#{entry} #{kind} preparation failures keep copied payloads funded for held callers" do
      scope = make_ref()
      owner = self()
      entry = unquote(entry)
      kind = unquote(kind)

      caller =
        spawn(fn ->
          results =
            for index <- 1..3 do
              opts = options(scope, owner, {entry, kind, index}, kind, 65_536)
              invoke(entry, opts)
            end

          Process.put(:held_preparation_failures, results)
          send(owner, {:held_preparation_failures, self(), Enum.map(results, &failure_size/1)})

          receive do
            :finish -> :ok
          end
        end)

      on_exit(fn ->
        Process.exit(caller, :kill)
        Store.dispose_scope(scope)
      end)

      preparations =
        for index <- 1..3 do
          id = {entry, kind, index}

          assert_receive {:modifier_preparation, ^id, executor, queue_owner, feeder}, 5_000
          {queue_owner, feeder, executor, Process.monitor(executor)}
        end

      assert_receive {:held_preparation_failures, ^caller,
                      [
                        {^kind, 65_536},
                        {^kind, 65_536},
                        {^kind, 65_536}
                      ]},
                     5_000

      for {_queue_owner, _feeder, executor, monitor} <- preparations do
        assert_receive {:DOWN, ^monitor, :process, ^executor, _}, 5_000
      end

      state =
        await(fn ->
          state = :sys.get_state(Store)

          for {_token, %{caller: ^caller, refs: [backing]}} <- state.execution_returns do
            assert state.resources.receipts[backing].holders[caller].status in [
                     :adopted,
                     :retained
                   ]
          end

          state
        end)

      refute Map.has_key?(state.scopes, scope)
      records = for {_token, %{caller: ^caller} = record} <- state.execution_returns, do: record
      assert length(records) == 3
      producers = MapSet.new(preparations, &elem(&1, 2))

      for record <- records do
        assert MapSet.member?(producers, record.producer)
        assert record.state == :accepted
        assert [backing] = record.refs
        assert state.resources.receipts[backing].actual >= 65_536
        assert state.resources.receipts[backing].holders[caller].status in [:adopted, :retained]
        assert state.resources.receipts[record.copy].kind == :return_copy
        assert state.resources.receipts[record.copy].actual >= 1_024
      end

      if entry == :async do
        Enum.each(preparations, fn {queue_owner, feeder, _, _} ->
          assert_queue_retired({queue_owner, feeder})
        end)
      end

      assert Crawler.Store.Resources.bytes(state.resources) <= state.resources.limit
      monitor = Process.monitor(caller)
      send(caller, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}

      await(fn ->
        current = :sys.get_state(Store)
        refute Map.has_key?(current.return_callers, caller)

        for record <- records, ref <- [record.copy | record.refs] do
          refute current.resources.receipts[ref]
        end
      end)
    end
  end

  test "unsupported preparation payload funding returns a fixed limit and stops an owned queue" do
    for entry <- [:direct, :async] do
      scope = make_ref()
      id = {:refused, entry}

      opts =
        options(scope, self(), id, :throw, 1_048_576)
        |> Map.merge(%{max_body: 0, max_analysis_bytes: 500_000})

      assert {:returned, {:error, {:limit, :max_retained_bytes}}} = invoke(entry, opts)
      assert_receive {:modifier_preparation, ^id, _executor, owner, feeder}
      if entry == :async, do: assert_queue_retired({owner, feeder})
      refute Map.has_key?(:sys.get_state(Store).scopes, scope)
      on_exit(fn -> Store.dispose_scope(scope) end)
    end
  end

  test "failed preparation leaves an existing borrowed queue and its owner running" do
    scope = make_ref()
    base = options(scope, self(), :borrowed, :throw, 65_536)
    owner = start_supervised!({Queue, base})
    feeder = Queue.feeder(owner)
    on_exit(fn -> Store.dispose_scope(scope) end)

    for kind <- [:throw, :exit] do
      opts = Map.merge(base, %{queue: feeder, failure_kind: kind, failure_id: {:borrowed, kind}})
      assert {:raised, ^kind, {:modifier_payload, body}} = invoke(:async, opts)
      assert byte_size(body) == 65_536
      assert Process.alive?(owner)
      assert Process.alive?(feeder)
      assert %{owner: ^owner} = Store.queue_record(feeder)
      assert %{status: :active} = QueueTickets.status(feeder)
    end
  end

  test "caller death during held preparation terminates newly owned queue custody" do
    scope = make_ref()
    owner = self()
    opts = options(scope, owner, :caller_down, :throw, 65_536)

    caller =
      spawn(fn ->
        Crawler.crawl(opts.url, Map.put(opts, :hold_preparation, true))
      end)

    on_exit(fn ->
      Process.exit(caller, :kill)
      Store.dispose_scope(scope)
    end)

    assert_receive {:modifier_preparation, :caller_down, executor, queue_owner, feeder}, 5_000
    monitors = Enum.map([caller, executor, queue_owner, feeder], &{&1, Process.monitor(&1)})
    Process.exit(caller, :kill)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
      refute Process.alive?(pid)
    end

    assert_queue_retired({queue_owner, feeder})
    refute Map.has_key?(:sys.get_state(Store).scopes, scope)
  end

  test "child preparation keeps the root executor and deadline across a normal graph" do
    scope = make_ref()
    observer = self()
    children = Enum.map_join(1..8, "", &"<a href='/child-#{&1}'>child</a>")

    adapter = fn request ->
      body = if request.url.path == "/root", do: children, else: "child"

      if request.url.path == "/root" do
        send(observer, {
          :root_execution,
          self(),
          Process.get(:crawler_execution_lease),
          request.options[:crawler_deadline]
        })

        receive do
          :release_root -> :ok
        end
      end

      {request,
       Req.Response.new(status: 200, body: body, headers: [{"content-type", "text/html"}])}
    end

    opts = %{
      scope: scope,
      failure_owner: observer,
      modifier: ObservedModifier,
      workers: 1,
      retries: 0,
      respect_robots: false,
      max_body: 262_144,
      max_analysis_bytes: 4_194_304,
      req_options: [adapter: adapter]
    }

    assert {:ok, bound} = Crawler.crawl("https://preparation.test/root", opts)
    on_exit(fn -> Crawler.stop(bound) end)
    assert :erts_debug.same(bound.req_options[:adapter], adapter)
    assert :sys.get_state(bound.queue_owner).admission == nil
    assert_receive {:root_execution, executor, lease, deadline}, 5_000
    assert is_reference(lease)
    assert %Crawler.Deadline{} = deadline
    send(executor, :release_root)

    for _ <- 1..8 do
      assert_receive {:child_preparation, ^executor, ^lease, ^deadline}, 5_000
    end

    await(fn ->
      assert Store.ops_count(scope) == 9
      assert Store.pending_count(scope) == 0
      refute Crawler.running?(bound)
    end)
  end

  test "a claimed parent can prebind child cookies without gaining child mutation authority" do
    scope = make_ref()
    url = "https://preparation.test/cookies"
    generation = Store.generation(scope)
    observer = self()
    on_exit(fn -> Store.dispose_scope(scope) end)
    assert :ok = Store.save_cookies(scope, url, ["id=one; Path=/; Secure"], generation)

    opts =
      Crawler.Options.assign_defaults(%{
        scope: scope,
        generation: generation,
        url: url,
        preparation?: true,
        respect_robots: false,
        credentials: :include,
        cookie_site: url
      })

    assert :ok =
             Crawler.Store.Execution.run_job(opts, fn owned ->
               assert owned.queue == nil
               refute Store.current?(scope, generation, observer)
               child = Map.put(owned, :queue, observer)
               before = :sys.get_state(Store).cookies[scope]

               assert {:ok, "id=one", observation} =
                        Store.cookie_snapshot(scope, url, generation, child, owned.cookie_proof)

               assert observation.proof.generation === generation

               assert {:error, :stale} =
                        Store.save_cookies_with_proof(
                          scope,
                          url,
                          ["id=two; Path=/; Secure"],
                          generation,
                          child,
                          observation.proof
                        )

               assert {:error, :stale} =
                        Store.validate_cookie_proof(scope, generation, child, observation.proof)

               assert {:error, :stale} =
                        Store.cookie_snapshot(make_ref(), url, nil, child, :unbound)

               assert :sys.get_state(Store).cookies[scope] === before
               :ok
             end)
  end

  defp options(scope, observer, id, kind, bytes) do
    Crawler.Options.assign_defaults(%{
      scope: scope,
      url: "https://preparation.test/failure",
      modifier: FailingModifier,
      failure_owner: observer,
      failure_id: id,
      failure_kind: kind,
      failure_bytes: bytes,
      workers: 1,
      retries: 0,
      respect_robots: false,
      max_body: 262_144,
      max_analysis_bytes: 1_048_576
    })
  end

  defp invoke(entry, opts) do
    result =
      case entry do
        :direct -> Crawler.crawl_now(opts)
        :async -> Crawler.crawl(opts.url, opts)
      end

    {:returned, result}
  catch
    kind, reason -> {:raised, kind, reason}
  end

  defp failure_size({:returned, {:error, {kind, {:modifier_payload, body}}}}),
    do: {kind, byte_size(body)}

  defp failure_size({:raised, kind, {:modifier_payload, body}}), do: {kind, byte_size(body)}
  defp failure_size(_), do: :unexpected_result

  defp assert_queue_retired({owner, feeder}) do
    for pid <- [owner, feeder] do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
      refute Process.alive?(pid)
    end

    await(fn ->
      assert QueueTickets.status(feeder) == :untracked
      assert Store.queue_record(feeder) == nil
      assert Registry.lookup(OPQ.Registry, feeder) == []
      refute Map.has_key?(:persistent_term.get({QueueTickets, :enrollments}, %{}), feeder)
    end)
  end

  defp await(check, attempts \\ 200)
  defp await(check, 0), do: check.()

  defp await(check, attempts) do
    check.()
  rescue
    ExUnit.AssertionError ->
      receive do
      after
        10 -> await(check, attempts - 1)
      end
  end
end
