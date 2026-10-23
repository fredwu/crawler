defmodule Crawler.Store.SettlementTest do
  use Crawler.TestCase, async: false

  alias Crawler.SettlementClaimHelpers

  alias Crawler.Queue
  alias Crawler.QueueTickets
  alias Crawler.Store

  defmodule ObservedStore do
    def add_page_data({url, _scope}, body, opts) do
      if url == opts[:landing_url] do
        if opts[:hold_fallback] do
          send(opts.observer, {:fallback_started, self()})

          receive do
            :release_fallback -> :ok
          end
        end

        message =
          if opts[:tagged_fallback],
            do: {:fallback_stored, url, body},
            else: {:fallback_stored, body}

        send(opts.observer, message)
        opts[:fallback_error] || :ok
      else
        :ok
      end
    end
  end

  setup do
    scope = unique_scope("settlement-transition")
    owner = start_supervised!({Queue, %{scope: scope, workers: 1, interval: 0, timeout: 5_000}})
    queue = Queue.feeder(owner)
    OPQ.pause(queue)
    on_exit(fn -> Store.drop_scope(scope) end)

    {:ok, %{scope: scope, queue: queue, generation: Store.generation(scope)}}
  end

  test "multiple retained fallbacks share one physical ticket and all progress", context do
    rigs = queued_fallbacks(context)
    receipts = Enum.flat_map(rigs, &candidate(&1).resources)
    assert_queued_ticket(context, rigs)
    OPQ.resume(context.queue)

    stored =
      for _rig <- rigs do
        assert_receive {:fallback_stored, url, "FALLBACK"}, 2_000
        assert_ticket_cap(context.queue)
        url
      end

    assert Enum.sort(stored) == Enum.sort(Enum.map(rigs, & &1.landing))
    refute_receive {:fallback_stored, _, _}
    await_idle(hd(rigs).source_opts)

    for rig <- rigs do
      assert Store.find_processed({rig.landing, context.scope})
      assert source_outcome(rig).status == :succeeded
    end

    assert Store.ops_count(context.scope) == length(rigs)
    assert_released(receipts)
    assert_idle(context.scope)
    wait(fn -> assert %{outstanding: 0} = QueueTickets.status(context.queue) end)
    assert_ticket_cap(context.queue)
  end

  for release <- [:acknowledgement, :queue_death] do
    test "scope reset retains its transport ticket until #{release}", context do
      rigs = queued_fallbacks(context)
      receipts = Enum.flat_map(rigs, &candidate(&1).resources)
      ticket = assert_queued_ticket(context, rigs)
      generation = Store.drop_scope(context.scope)
      refute generation == context.generation

      wait(fn ->
        assert :sys.get_state(Store).settlements.candidates == %{}
        assert :sys.get_state(Store).settlements.ready == %{}
        assert :sys.get_state(Store).settlements.pending == %{}
        assert_released(receipts)
      end)

      assert paused_ticket(context.queue) == ticket
      assert %{outstanding: 1} = QueueTickets.status(context.queue)
      assert Store.ops_count(context.scope) == 0

      case unquote(release) do
        :acknowledgement ->
          OPQ.resume(context.queue)
          wait(fn -> assert %{outstanding: 0} = QueueTickets.status(context.queue) end)
          assert {:normal, %OPQ.Queue{data: data}, _} = OPQ.info(context.queue)
          assert :queue.is_empty(data)
          assert Process.alive?(context.queue)

        :queue_death ->
          Process.exit(context.queue, :kill)
          wait(fn -> assert QueueTickets.status(context.queue) == :untracked end)
      end

      assert QueueTickets.ack(ticket) == {:error, :stale_ticket}
      refute_receive {:fallback_stored, _, _}
      assert_released(receipts)
      assert_idle(context.scope)
    end
  end

  test "run expiry retires queued fallbacks while their physical ticket remains charged",
       context do
    context = Map.put(context, :run_timeout, 2_000)
    rigs = queued_fallbacks(context)
    receipts = Enum.flat_map(rigs, &candidate(&1).resources)
    ticket = assert_queued_ticket(context, rigs)

    wait(fn ->
      state = :sys.get_state(Store)
      assert state.scopes[context.scope].outcome == {:limited, {:deadline, :run}}
      assert state.settlements.candidates == %{}
      assert state.settlements.ready == %{}
      assert state.settlements.pending == %{}
      assert_released(receipts)
      assert_idle(context.scope)
    end)

    assert Store.generation(context.scope) == context.generation
    assert Process.alive?(context.queue)
    assert paused_ticket(context.queue) == ticket
    assert %{outstanding: 1} = QueueTickets.status(context.queue)
    OPQ.resume(context.queue)
    wait(fn -> assert %{outstanding: 0} = QueueTickets.status(context.queue) end)
    assert QueueTickets.ack(ticket) == {:error, :stale_ticket}
    refute_receive {:fallback_stored, _, _}
  end

  test "an issued settlement retains its custody across run expiry until its claim finishes",
       context do
    context = Map.put(context, :run_timeout, 2_000)
    [rig] = queued_fallbacks(context, 1)
    receipts = candidate(rig).resources
    ticket = assert_queued_ticket(context, [rig])
    observer = self()

    actor =
      spawn(fn ->
        assert {:ok, token, _options, bytes} = Store.start_settlement(rig.ref)
        send(observer, {:settlement_issued, self(), token, bytes})

        receive do
          :release_claim ->
            assert :ok = Store.finish_claim(token)
            send(observer, {:settlement_released, self()})
        end
      end)

    on_exit(fn -> Process.exit(actor, :kill) end)
    assert_receive {:settlement_issued, ^actor, token, bytes}, 2_000
    assert bytes > 0
    assert candidate(rig).status == {:running, token}
    assert :sys.get_state(Store).settlements.ready == %{}
    assert :sys.get_state(Store).settlements.pending == %{}

    wait(fn ->
      assert :sys.get_state(Store).scopes[context.scope].outcome ==
               {:limited, {:deadline, :run}}
    end)

    state = :sys.get_state(Store)
    assert Process.alive?(actor)
    assert Process.alive?(context.queue)
    assert Store.generation(context.scope) == context.generation
    assert candidate(rig).status == {:running, token}
    assert Crawler.Store.Claims.owned?(state.claims, token, actor)
    assert state.settlements.ready == %{}
    assert state.settlements.pending == %{}
    assert Store.pending_count(context.scope) == 1

    for receipt <- receipts do
      assert Map.has_key?(state.resources.receipts, receipt)
      assert MapSet.member?(state.persistent_resources, receipt)
      assert state.persistent_counts[receipt] == {0, 1}
    end

    assert paused_ticket(context.queue) == ticket
    assert %{outstanding: 1} = QueueTickets.status(context.queue)
    monitor = Process.monitor(actor)
    send(actor, :release_claim)
    assert_receive {:settlement_released, ^actor}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^actor, :normal}, 2_000
    wait(fn -> refute Map.has_key?(:sys.get_state(Store).claims.active, token) end)
    assert_released(receipts)
    assert_idle(context.scope)
    OPQ.resume(context.queue)
    wait(fn -> assert %{outstanding: 0} = QueueTickets.status(context.queue) end)
    assert QueueTickets.ack(ticket) == {:error, :stale_ticket}
    refute_receive {:fallback_stored, _, _}
  end

  for retirement <- [:run_expiry, :queue_retirement, :direct_expiry] do
    test "#{retirement} releases completed alias custody before scope disposal", context do
      exercise_completed_alias_retirement(context, unquote(retirement))
    end
  end

  for retirement <- [:reset, :dispose, :queue_death], ending <- [:release, :down] do
    test "an issued settlement survives #{retirement} until #{ending} without touching replacement work",
         context do
      exercise_issued_retirement(context, unquote(retirement), unquote(ending))
    end
  end

  for retirement <- [:reset, :source_queue_death] do
    test "retired issued custody cannot suppress a current fallback after #{retirement}",
         context do
      exercise_retired_competition(context, unquote(retirement))
    end
  end

  test "disposing a shared Page receipt preserves its issued settlement custody", context do
    context = Map.put(context, :share_candidate_page, true)
    rig = retain_fallback(context, :default, &start_completed_source/3, true)
    [receipt] = candidate(rig).resources
    source = {rig.source_opts.url, context.scope}
    assert Store.find(source).opts.page_resource == receipt
    publish_source(rig, :succeeded)
    finish_landing(rig)
    assert candidate(rig).status == :queued
    state = :sys.get_state(Store)
    assert state.persistent_counts[receipt] == {1, 1}
    assert Map.has_key?(state.retained_pages[context.scope].members, receipt)
    original = state.resources.receipts[receipt]
    assert original.actual > 0
    {actor, token} = issue_settlement(rig)
    assert :ok = Store.dispose_scope(context.scope, context.generation)

    wait(fn ->
      state = :sys.get_state(Store)
      assert state.scope_disposals == %{}
      assert Crawler.Frontier.Ring.size(state.retiring_runs) == 0
      assert Crawler.Store.Claims.owned?(state.claims, token, actor)
      assert candidate(rig).status == {:running, token}
      assert state.persistent_counts[receipt] == {0, 1}
      assert MapSet.member?(state.persistent_resources, receipt)
      assert state.resources.receipts[receipt].actual == original.actual
      assert Map.has_key?(state.resources.receipts[receipt].holders, Process.whereis(Store))
      refute Map.has_key?(state.retained_pages, context.scope)
      refute Store.find(source)
    end)

    assert Process.alive?(actor)
    finish_issued_actor(actor, token, :release)

    wait(fn ->
      assert candidate(rig) == nil
      assert_released([receipt])
    end)

    OPQ.resume(context.queue)
    wait(fn -> assert %{outstanding: 0} = QueueTickets.status(context.queue) end)
    refute_receive {:fallback_stored, _}
  end

  for {name, options, reason} <- [
        {:attempt_timeout, %{hold_fallback: true, attempt_timeout: 1_000}, {:deadline, :attempt}},
        {:resource_limit, %{fallback_error: {:error, {:limit, :max_retained_bytes}}},
         {:limit, :max_retained_bytes}}
      ] do
    test "a fallback #{name} reports its limit after a successful canonical source", context do
      context = Map.merge(context, unquote(Macro.escape(options)))
      rig = retain_fallback(context, :default, &start_completed_source/3, true)
      receipts = candidate(rig).resources
      publish_source(rig, :succeeded)
      finish_landing(rig)
      assert source_outcome(rig).status == :succeeded
      OPQ.resume(context.queue)
      assert_fallback_result(unquote(name))
      opts = Map.put(rig.source_opts, :target_handle, rig.source_claim.target)

      wait(fn ->
        assert {:ok, status} = Crawler.run_status(opts)
        assert status.state == :limited
        assert status.root_status == :succeeded
        assert status.reported_limit == unquote(Macro.escape(reason))
        assert status.reason == unquote(Macro.escape(reason))
        assert status.terminal?
        assert status.pending == 0
        assert status.inflight == 0
        assert_idle(context.scope)
        assert_released(receipts)
      end)

      assert Store.ops_count(context.scope) == 1
      refute Store.find_processed({rig.landing, context.scope})
      refute_receive {:fallback_stored, _}
    end
  end

  test "only the issued fallback owner can report a limit in its current generation", context do
    [rig] = queued_fallbacks(context, 1)
    receipts = candidate(rig).resources
    observer = self()

    actor =
      spawn(fn ->
        assert {:ok, token, _options, _bytes} = Store.start_settlement(rig.ref)
        send(observer, {:settlement_issued, self(), token})

        receive do
          :release_claim ->
            assert :ok = Store.finish_claim(token, {:limit, :max_retained_bytes})
            send(observer, {:settlement_released, self()})
        end
      end)

    on_exit(fn -> Process.exit(actor, :kill) end)
    assert_receive {:settlement_issued, ^actor, token}, 2_000
    state = :sys.get_state(Store)
    claim = state.claims.active[token]
    assert claim.worker == actor
    assert candidate(rig).status == {:running, token}
    assert :ok = Store.finish_claim(token, {:deadline, :attempt})
    state = :sys.get_state(Store)
    assert state.claims.active[token] == claim
    assert candidate(rig).status == {:running, token}
    assert state.scopes[context.scope].reported_limit == nil
    assert Store.pending_count(context.scope) == 1

    generation = Store.drop_scope(context.scope)
    refute generation == context.generation
    replacement_opts = %{rig.target_opts | generation: generation, url: rig.landing <> "/new"}
    assert {:ok, replacement} = Crawler.crawl(replacement_opts.url, replacement_opts)
    assert {:ok, before_status} = Crawler.run_status(replacement)
    monitor = Process.monitor(actor)
    send(actor, :release_claim)
    assert_receive {:settlement_released, ^actor}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^actor, :normal}, 2_000
    assert {:ok, ^before_status} = Crawler.run_status(replacement)
    assert before_status.reported_limit == nil
    assert before_status.pending == 1

    assert {:error, :stale} =
             Crawler.run_status(Map.put(rig.source_opts, :target_handle, rig.source_claim.target))

    wait(fn ->
      assert :sys.get_state(Store).settlements.candidates == %{}
      refute Map.has_key?(:sys.get_state(Store).claims.active, token)
      assert_released(receipts)
    end)

    refute_receive {:fallback_stored, _, _}
  end

  test "candidate and scheduling indexes fit their fixed retained charge", context do
    queue = context.queue
    ref = make_ref()

    skeleton = %Crawler.Store.Settlements.Candidate{
      key: :funded_key,
      source_key: :funded_source_key,
      generation: :funded_generation,
      body: :funded_body,
      opts: :funded_opts,
      source_ref: make_ref(),
      worker: self(),
      queue: queue,
      target_queue: queue,
      target_handle: make_ref(),
      resources: [make_ref()],
      source_done?: true,
      status: {:running, make_ref()}
    }

    bookkeeping = {
      %{ref => skeleton},
      %{queue => %{ref => true}},
      %{funded_run: %{ref => true}},
      MapSet.new([queue]),
      {0, 1}
    }

    charge = Crawler.Store.Settlements.bookkeeping_bytes()
    assert charge == 4_096
    assert {:ok, measured} = Crawler.Store.Retained.bytes(bookkeeping, charge)
    assert measured <= charge
  end

  test "a processed source waits for its successful canonical outcome before fallback", context do
    rig = retain_fallback(context, :default, &start_completed_source/3)
    receipts = candidate(rig).resources
    assert Store.find_processed({rig.source_opts.url, context.scope})
    assert source_outcome(rig) == nil
    finish_landing(rig)
    assert candidate(rig).status == :waiting
    assert :skip = Store.start_settlement(rig.ref)
    OPQ.resume(context.queue)
    refute_receive {:fallback_stored, _}

    publish_source(rig, :succeeded)
    assert_receive {:fallback_stored, "FALLBACK"}, 2_000
    await_idle(rig.source_opts)
    refute_receive {:fallback_stored, _}
    assert Store.find_processed({rig.landing, context.scope})
    assert source_outcome(rig).status == :succeeded
    assert Store.ops_count(context.scope) == 1
    assert_released(receipts)
    assert_idle(context.scope)
  end

  test "an already processed source variant completes its retained redirect fallback", context do
    source = context.url <> "/settlement/source"

    ReqTestSite.expect_once(context.site, "GET", URI.parse(source).path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.resp(200, "LANDING")
    end)

    previous =
      context
      |> target_options(source)
      |> Map.put(:req_options, context.req_options)
      |> claim_worker(true, true)

    send(previous.executor, :complete_landing)
    previous_worker = previous.worker
    assert_receive {:landing_completed, ^previous_worker}, 2_000
    finish_local_landing(previous, :succeeded)
    assert Store.find_processed({source, context.scope})
    assert %{status: :succeeded} = Store.target_outcome(previous.target)
    assert Store.ops_count(context.scope) == 1

    context =
      Map.merge(context, %{
        javascript_goal: :module,
        req_options:
          Keyword.put(context.req_options, :headers, [{"x-source-variant", "redirect"}])
      })

    rig = retain_fallback(context, :default, &start_completed_source/3, true)
    receipts = candidate(rig).resources
    refute rig.source_claim.target == previous.target
    assert candidate(rig).source_key == {source, context.scope}
    assert candidate(rig).source_done?
    assert Store.find_processed({source, context.scope})
    publish_source(rig, :succeeded)
    assert source_outcome(rig).status == :succeeded
    finish_landing(rig)
    OPQ.resume(context.queue)
    assert_receive {:fallback_stored, "FALLBACK"}, 2_000
    await_idle(rig.source_opts)
    refute_receive {:fallback_stored, _}
    assert Store.find_processed({rig.landing, context.scope})
    assert Store.ops_count(context.scope) == 1
    assert_released(receipts)
    assert_idle(context.scope)
  end

  test "a completed landing worker exit preserves its running fallback", context do
    context = Map.put(context, :hold_fallback, true)
    rig = retain_fallback(context, :default, &start_completed_source/3, true)
    receipts = candidate(rig).resources
    publish_source(rig, :succeeded)
    worker = rig.landing_worker
    send(worker, :complete)
    assert_receive {:completed, ^worker, claim}, 2_000
    assert candidate(rig).status == :queued
    OPQ.resume(context.queue)
    assert_receive {:fallback_started, callback}, 2_000
    on_exit(fn -> send(callback, :release_fallback) end)
    assert {:running, _token} = candidate(rig).status

    monitor = Process.monitor(worker)
    send(worker, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    wait(fn -> refute Map.has_key?(:sys.get_state(Store).scheduler_workers, claim) end)

    key = {rig.landing, context.scope}
    assert %Crawler.Store.Page{processed: nil} = Store.find(key)
    assert Crawler.Store.State.page_owner(:sys.get_state(Store), key) == {:owned, context.queue}
    assert Store.pending_count(context.scope) == 1
    send(callback, :release_fallback)
    assert_receive {:fallback_stored, "FALLBACK"}, 2_000
    await_idle(rig.source_opts)
    refute_receive {:fallback_stored, _}
    assert Store.find_processed(key)
    assert Store.ops_count(context.scope) == 1
    assert_released(receipts)
    assert_idle(context.scope)
  end

  for status <- [:failed, :limited, :cancelled] do
    test "a processed source with a #{status} canonical outcome discards its fallback", context do
      rig = retain_fallback(context, :default, &start_completed_source/3)
      receipts = candidate(rig).resources
      assert Store.find_processed({rig.source_opts.url, context.scope})
      finish_landing(rig)
      assert candidate(rig).status == :waiting
      OPQ.resume(context.queue)
      publish_source(rig, unquote(status))
      await_idle(rig.source_opts)
      refute_receive {:fallback_stored, _}
      refute Store.find_processed({rig.landing, context.scope})
      assert source_outcome(rig).status == unquote(status)
      assert Store.ops_count(context.scope) == 0
      assert_released(receipts)
      assert_idle(context.scope)
    end
  end

  for order <- [:completed_before_second_retained, :both_retained_before_completion],
      status <- [:failed, :limited, :cancelled] do
    test "a #{status} source cannot displace the successful fallback when #{order}", context do
      context = Map.put(context, :source_body, "FIRST")

      first_context =
        Map.put(
          context,
          :defer_source_completion,
          unquote(order) == :both_retained_before_completion
        )

      first = retain_fallback(first_context, :default, &start_completed_source/3, true)
      first_receipts = candidate(first).resources
      assert source_outcome(first) == nil

      second_context =
        Map.merge(context, %{
          source_suffix: "/second",
          source_body: "SUCCESSFUL SECOND",
          landing_worker: first.landing_worker
        })

      second = retain_fallback(second_context, :default, &start_completed_source/3, true)
      assert first.ref != second.ref
      receipts = first_receipts ++ candidate(second).resources
      complete_deferred_source(first, unquote(order))
      assert Store.find_processed({first.source_opts.url, context.scope})
      assert source_outcome(first) == nil
      assert candidate(first).body == "FIRST"
      assert candidate(second).body == "SUCCESSFUL SECOND"
      assert candidate(first).status == :waiting
      assert candidate(second).status == :waiting
      publish_source(second, :succeeded)
      publish_source(first, unquote(status))
      assert source_outcome(first).status == unquote(status)
      assert source_outcome(second).status == :succeeded
      finish_landing(first)
      OPQ.resume(context.queue)
      assert_receive {:fallback_stored, "SUCCESSFUL SECOND"}, 2_000
      await_idle(second.source_opts)
      refute_receive {:fallback_stored, _}
      assert Store.find_processed({first.landing, context.scope})
      assert Store.ops_count(context.scope) == 1
      assert_released(receipts)
      assert_idle(context.scope)
      wait(fn -> assert %{outstanding: 0} = QueueTickets.status(context.queue) end)
    end
  end

  for order <- [:retained_before_landing_completion, :retained_after_landing_completion],
      status <- [:failed, :limited, :cancelled, :succeeded] do
    test "a locally completed landing with #{status} outcome settles correctly when #{order}",
         context do
      landing = context.url <> "/settlement/landing"

      ReqTestSite.expect_once(context.site, "GET", URI.parse(landing).path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.resp(200, "LANDING")
      end)

      landing_opts =
        Map.merge(target_options(context, landing), %{
          req_options: context.req_options,
          retries: 0
        })

      local = claim_worker(landing_opts, true, true)
      context = Map.put(context, :landing_worker, local.worker)
      maybe_complete_landing(local, unquote(order), :before_retention)
      rig = retain_fallback(context, :default, &start_completed_source/3, true)
      receipts = candidate(rig).resources
      assert candidate(rig).body == "FALLBACK"
      maybe_complete_landing(local, unquote(order), :after_retention)

      assert %Crawler.Store.Page{processed: true, target_handle: target} =
               Store.find({landing, context.scope})

      assert target == local.target
      assert Store.target_outcome(target) == nil
      publish_source(rig, :succeeded)
      assert source_outcome(rig).status == :succeeded
      assert candidate(rig).status == :waiting
      assert :skip = Store.start_settlement(rig.ref)
      assert candidate(rig).status == :waiting
      OPQ.resume(context.queue)
      refute_receive {:fallback_stored, _}
      finish_local_landing(local, unquote(status))
      assert_landing_result(unquote(status), rig)
      assert %{status: unquote(status)} = Store.target_outcome(local.target)
      assert Store.find_processed({landing, context.scope})
      assert_released(receipts)
      assert_idle(context.scope)
      wait(fn -> assert %{outstanding: 0} = QueueTickets.status(context.queue) end)
    end
  end

  test "a queued fallback waits for an intervening landing claim without losing its body",
       context do
    rig = retain_fallback(context)
    finish_source(rig)
    finish_landing(rig)
    assert candidate(rig).status == :queued
    next = claim_worker(Map.put(rig.target_opts, :javascript_goal, :module))
    assert :skip = Store.start_settlement(rig.ref)
    assert candidate(rig).status == :waiting
    assert Store.pending_count(context.scope) == 2
    finish_worker(next)
    assert candidate(rig).status == :queued
    OPQ.resume(context.queue)
    await_idle(rig.source_opts)
    assert Store.find_processed({rig.landing, context.scope}).body == "FALLBACK"
    assert Store.ops_count(context.scope) == 1
    assert_idle(context.scope)
  end

  test "an intervening nil-owned registration stays intact", context do
    rig = retain_fallback(context)
    finish_source(rig)
    assert :ok = Store.delete({rig.landing, context.scope}, context.generation, context.queue)
    assert {:ok, _} = Store.add({rig.landing, context.scope}, context.generation)
    Store.add_page_data({rig.landing, context.scope}, "DIRECT", %{scope: context.scope})
    finish_landing(rig)
    assert Store.find({rig.landing, context.scope}).body == "DIRECT"
    refute Store.find_processed({rig.landing, context.scope})
    assert_idle(context.scope)
  end

  test "an unrelated queued registration is not reset before its work settles", context do
    rig = retain_fallback(context)
    finish_source(rig)
    finish_landing(rig)
    assert :ok = Store.delete({rig.landing, context.scope}, context.generation, context.queue)

    other_owner =
      start_supervised!({Queue, %{scope: context.scope, workers: 1, interval: 0, timeout: 5_000}},
        id: :other_settlement_queue
      )

    other = Queue.feeder(other_owner)
    assert :ok = Store.note_enqueued(context.scope, context.generation, other)
    assert {:ok, _} = Store.add({rig.landing, context.scope}, context.generation, other)

    Store.add_page_data({rig.landing, context.scope}, "OTHER", %{
      scope: context.scope,
      generation: context.generation,
      queue: other
    })

    assert :skip = Store.start_settlement(rig.ref)
    assert Store.find({rig.landing, context.scope}).body == "OTHER"
    assert candidate(rig).status == :waiting
    assert :ok = Store.finish_work(context.scope, context.generation, false, other)
    assert candidate(rig).status == :queued
    OPQ.resume(context.queue)
    await_idle(rig.source_opts)
    assert Store.find_processed({rig.landing, context.scope}).body == "FALLBACK"
    assert_idle(context.scope)
  end

  test "a queue-less synchronous source cannot retain asynchronous work", context do
    rig = retain_fallback(context, nil)
    assert rig.ref == nil
    finish_source(rig)
    finish_landing(rig)
    assert Process.alive?(Process.whereis(Store))
    assert_idle(context.scope)
  end

  test "retiring the landing queue promotes a completed fallback on its surviving source queue",
       context do
    queue = another_queue(context)
    rig = retain_fallback(context, queue)
    finish_source(rig)
    source = candidate(rig).opts.target_handle
    assert %{status: :succeeded} = Store.target_outcome(source)
    Process.exit(context.queue, :kill)
    wait(fn -> assert candidate(rig).status == :queued end)
    assert Store.generation(context.scope) == context.generation
    OPQ.resume(queue)
    await_idle(rig.source_opts)
    assert Store.find_processed({rig.landing, context.scope}).body == "FALLBACK"
    assert_idle(context.scope)
  end

  test "retiring the source queue discards its fallback and preserves the independent claim",
       context do
    queue = another_queue(context)
    rig = retain_fallback(context, queue)
    finish_source(rig)
    Process.exit(queue, :kill)
    wait(fn -> assert :sys.get_state(Store).settlements.candidates == %{} end)
    assert Store.inflight_count(context.scope) == 1
    assert Store.pending_count(context.scope) == 1
    assert Store.find({rig.landing, context.scope})
    finish_landing(rig)
    refute Store.find({rig.landing, context.scope})
    assert Store.find_processed({rig.source_opts.url, context.scope})
    assert_idle(context.scope)
  end

  defp another_queue(context) do
    owner =
      start_supervised!({Queue, %{scope: context.scope, workers: 1, interval: 0, timeout: 5_000}},
        id: :source_settlement_queue
      )

    queue = Queue.feeder(owner)
    OPQ.pause(queue)
    queue
  end

  defp exercise_retired_competition(context, retirement) do
    context = Map.merge(context, %{pair_suffix: "/competition", source_body: "RETIRED"})
    old = retain_fallback(context, :default, &start_completed_source/3, true)
    old_receipts = candidate(old).resources
    publish_source(old, :succeeded)
    finish_landing(old)
    assert candidate(old).status == :queued
    {actor, token} = issue_settlement(old)
    {current_context, keeper} = retire_competitor(context, retirement, old.landing)

    if retirement == :source_queue_death do
      assert source_outcome(old).status == :succeeded
    end

    before_ops = Store.ops_count(context.scope)

    current_context =
      Map.merge(current_context, %{
        source_suffix: "/replacement",
        source_body: "CURRENT FALLBACK",
        javascript_goal: :module
      })

    current = retain_fallback(current_context, :default, &start_completed_source/3, true)
    refute current.ref == old.ref
    assert candidate(current).body == "CURRENT FALLBACK"
    current_receipts = candidate(current).resources
    publish_source(current, :succeeded)
    assert candidate(current).status == :waiting
    assert source_outcome(current).status == :succeeded
    assert Store.ops_count(context.scope) == before_ops + 1
    assert_issued_custody(old, actor, token, old_receipts)
    finish_competition_keeper(keeper)
    finish_landing(current)
    OPQ.resume(current_context.queue)
    assert_receive {:fallback_stored, "CURRENT FALLBACK"}, 2_000
    await_idle(current.source_opts)
    refute_receive {:fallback_stored, _}
    assert candidate(current) == nil
    assert_released(current_receipts)
    assert Store.pending_count(context.scope) == 0
    assert Store.inflight_count(context.scope) == 0
    assert Store.ops_count(context.scope) == before_ops + 1
    page = Store.find_processed({current.landing, context.scope})
    assert page.alias_owner == {:completed, current.source_claim.target}
    assert candidate(old).body == "RETIRED"
    assert_issued_custody(old, actor, token, old_receipts)
    finish_issued_actor(actor, token, :release)

    wait(fn ->
      assert candidate(old) == nil
      assert_released(old_receipts)
    end)

    assert Store.find_processed({current.landing, context.scope}) == page
    assert Store.ops_count(context.scope) == before_ops + 1
    assert_idle(context.scope)
    wait(fn -> assert %{outstanding: 0} = QueueTickets.status(current_context.queue) end)
  end

  defp retire_competitor(context, :reset, _landing) do
    generation = Store.drop_scope(context.scope)
    refute generation == context.generation

    wait(fn ->
      state = :sys.get_state(Store)
      assert state.scope_disposals == %{}
      assert Crawler.Frontier.Ring.size(state.retiring_runs) == 0
      refute Map.has_key?(state.scheduler.frontier.runs, {context.scope, context.generation})
    end)

    {%{context | generation: generation}, nil}
  end

  defp retire_competitor(context, :source_queue_death, landing) do
    queue = another_queue(context)
    current_context = %{context | queue: queue}
    keeper = claim_worker(target_options(current_context, landing <> "/keep-generation"), true)
    Process.exit(context.queue, :kill)

    wait(fn ->
      assert Store.queue_record(context.queue) == nil
      assert QueueTickets.status(context.queue) == :untracked
    end)

    assert Store.generation(context.scope) == context.generation
    {current_context, keeper}
  end

  defp finish_competition_keeper(nil), do: :ok
  defp finish_competition_keeper(worker), do: finish_worker(worker)

  defp assert_issued_custody(rig, actor, token, receipts) do
    state = :sys.get_state(Store)
    assert Process.alive?(actor)
    assert Crawler.Store.Claims.owned?(state.claims, token, actor)
    assert candidate(rig).status == {:running, token}

    for receipt <- receipts do
      assert state.persistent_counts[receipt] == {0, 1}
      assert state.resources.receipts[receipt].actual > 0
      assert MapSet.member?(state.persistent_resources, receipt)
      assert Map.has_key?(state.resources.receipts[receipt].holders, Process.whereis(Store))
    end
  end

  defp exercise_issued_retirement(context, retirement, ending) do
    [rig] = queued_fallbacks(context, 1)
    receipts = candidate(rig).resources
    {actor, token} = issue_settlement(rig)
    queue = retire_issued_queue(context, retirement)

    wait(fn ->
      state = :sys.get_state(Store)
      assert Crawler.Store.Claims.owned?(state.claims, token, actor)
      assert candidate(rig).status == {:running, token}
      assert state.settlements.ready == %{}
      assert state.settlements.pending == %{}

      for receipt <- receipts do
        assert state.persistent_counts[receipt] == {0, 1}
        assert Map.has_key?(state.resources.receipts, receipt)
      end
    end)

    replacement_context = %{context | queue: queue, generation: Store.generation(context.scope)}
    refute replacement_context.generation == context.generation

    ReqTestSite.expect_once(context.site, "GET", URI.parse(rig.landing).path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.resp(200, "LANDING")
    end)

    replacement =
      replacement_context
      |> target_options(rig.landing)
      |> Map.put(:req_options, context.req_options)
      |> claim_worker(true, true)

    key = {rig.landing, context.scope}
    page = Store.find(key)
    assert page.body == "LANDING"
    replacement_receipts = Crawler.Store.ResourceManager.page_receipts(page.opts)
    assert MapSet.size(replacement_receipts) > 0
    ops = Store.ops_count(context.scope)
    assert Store.pending_count(context.scope) == 1
    finish_issued_actor(actor, token, ending)

    wait(fn ->
      refute Map.has_key?(:sys.get_state(Store).claims.active, token)
      assert candidate(rig) == nil
      assert_released(receipts)
    end)

    assert Store.find(key) == page
    assert Store.pending_count(context.scope) == 1
    assert Store.ops_count(context.scope) == ops
    assert Crawler.Store.State.page_owner(:sys.get_state(Store), key) == {:owned, queue}

    for receipt <- replacement_receipts do
      state = :sys.get_state(Store)
      assert state.persistent_counts[receipt] == {1, 0}
      assert Map.has_key?(state.resources.receipts, receipt)
    end

    send(replacement.executor, :complete_landing)
    replacement_worker = replacement.worker
    assert_receive {:landing_completed, ^replacement_worker}, 2_000
    finish_local_landing(replacement, :succeeded)
    assert Store.find_processed(key).body == "LANDING"
    assert %{status: :succeeded} = Store.target_outcome(replacement.target)
    assert Store.ops_count(context.scope) == ops + 1
    assert_idle(context.scope)
    refute_receive {:fallback_stored, _, _}
  end

  defp issue_settlement(rig) do
    observer = self()

    actor =
      spawn(fn ->
        assert {:ok, token, _options, _bytes} = Store.start_settlement(rig.ref)
        send(observer, {:settlement_issued, self(), token})

        receive do
          :release_claim ->
            assert :ok = Store.finish_claim(token)
            send(observer, {:settlement_released, self()})
        end
      end)

    on_exit(fn -> Process.exit(actor, :kill) end)
    assert_receive {:settlement_issued, ^actor, token}, 2_000
    {actor, token}
  end

  defp retire_issued_queue(context, :reset) do
    refute Store.drop_scope(context.scope) == context.generation
    context.queue
  end

  defp retire_issued_queue(context, :dispose) do
    assert :ok = Store.dispose_scope(context.scope, context.generation)
    context.queue
  end

  defp retire_issued_queue(context, :queue_death) do
    Process.exit(context.queue, :kill)

    wait(fn ->
      assert QueueTickets.status(context.queue) == :untracked
      assert Store.queue_record(context.queue) == nil
    end)

    another_queue(context)
  end

  defp finish_issued_actor(actor, token, ending) do
    monitor = Process.monitor(actor)

    case ending do
      :release ->
        send(actor, :release_claim)
        assert_receive {:settlement_released, ^actor}, 2_000
        assert_receive {:DOWN, ^monitor, :process, ^actor, :normal}, 2_000

      :down ->
        Process.exit(actor, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^actor, :killed}, 2_000
    end

    wait(fn -> refute Map.has_key?(:sys.get_state(Store).claims.active, token) end)
  end

  defp exercise_completed_alias_retirement(context, retirement) do
    queue = if retirement == :direct_expiry, do: nil, else: context.queue
    timeout = if retirement == :queue_retirement, do: 30_000, else: 2_000
    options = Map.merge(context, %{queue: queue, run_timeout: timeout})
    successful = start_completed_alias(options, "accepted", nil)
    finish_completed_alias(successful)
    successful_source = Store.find_processed(successful.source)
    successful_landing = Store.find_processed(successful.landing)
    assert successful_source.body == "ACCEPTED"
    assert successful_landing.body == "ACCEPTED"
    assert %{status: :succeeded} = Store.target_outcome(successful.target)

    successful_resources =
      MapSet.union(
        Crawler.Store.ResourceManager.page_receipts(successful_source.opts),
        Crawler.Store.ResourceManager.page_receipts(successful_landing.opts)
      )

    baseline = :sys.get_state(Store)
    successful_counts = Map.take(baseline.persistent_counts, MapSet.to_list(successful_resources))
    assert Store.ops_count(context.scope) == 1

    observer = self()
    holder = spawn(fn -> hold_retired_body(observer) end)
    on_exit(fn -> Process.exit(holder, :kill) end)
    held = start_completed_alias(options, "provisional", holder)
    assert_receive {:retired_body_held, ^holder, body_receipt}, 2_000
    assert body_receipt === held.body_receipt
    state = :sys.get_state(Store)
    assert state.scheduler_workers[held.claim].completed_alias == {held.landing, held.receipt}
    assert state.persistent_counts[held.receipt] == {1, 0}
    assert MapSet.member?(state.persistent_resources, held.receipt)
    assert Map.has_key?(state.retained_pages[context.scope].members, held.receipt)
    assert Map.has_key?(state.resources.receipts[held.receipt].holders, Process.whereis(Store))

    assert [_] =
             :ets.lookup(Crawler.Store.Resources, {:grant, held.receipt, Process.whereis(Store)})

    assert Store.find_processed(held.source)
    assert Store.target_outcome(held.target) == nil
    assert Store.ops_count(context.scope) == 1
    monitor = Process.monitor(held.worker)
    if retirement == :queue_retirement, do: assert(:ok = Store.release_queue(context.queue))
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000

    wait(fn ->
      state = :sys.get_state(Store)
      refute Map.has_key?(state.scheduler_workers, held.claim)
      refute Store.find(held.source)
      refute Store.find_processed(held.source)
      refute Store.find(held.landing)
      assert_released([held.receipt])
      ring = Map.get(state.retained_pages, context.scope, Crawler.Frontier.Ring.new())
      refute Map.has_key?(ring.members, held.receipt)

      assert :ets.lookup(Crawler.Store.Resources, {:grant, held.receipt, Process.whereis(Store)}) ==
               []

      assert Store.find_processed(successful.source) === successful_source
      assert Store.find_processed(successful.landing) === successful_landing
      assert Map.take(state.persistent_counts, Map.keys(successful_counts)) === successful_counts
      assert Store.ops_count(context.scope) == 1
      assert state.resources.receipts[body_receipt].holders[holder].status == :adopted
      refute Map.has_key?(state.resources.receipts[body_receipt].holders, Process.whereis(Store))
      assert_idle(context.scope)
    end)

    if retirement != :queue_retirement do
      assert :sys.get_state(Store).scopes[context.scope].outcome == {:limited, {:deadline, :run}}
      assert Store.generation(context.scope) === context.generation
    else
      assert :ok = Store.release_queue(context.queue)
    end

    assert_released([held.receipt])
    holder_monitor = Process.monitor(holder)
    send(holder, :drop)
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :normal}, 2_000
    wait(fn -> assert_released([held.receipt, body_receipt]) end)
    assert Store.find_processed(successful.landing) === successful_landing
    assert Store.ops_count(context.scope) == 1
  end

  defp start_completed_alias(context, label, holder) do
    source = context.url <> "/retirement-alias/" <> label
    landing = source <> "/landing"

    ReqTestSite.expect_once(context.site, "GET", URI.parse(source).path, fn conn ->
      conn |> Plug.Conn.put_resp_header("location", landing) |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect_once(context.site, "GET", URI.parse(landing).path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.resp(200, String.upcase(label))
    end)

    opts =
      target_options(context, source)
      |> Map.merge(%{
        queue: context.queue,
        req_options: context.req_options,
        respect_robots: false,
        retries: 0,
        max_body: 1_024,
        max_analysis_bytes: 2_097_152,
        fixture_holder: holder
      })

    opts = admit_completed_alias(opts)
    observer = self()
    worker = spawn(fn -> run_completed_alias(opts, observer) end)
    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:canonical_alias_completed, ^worker, held}, 2_000
    held
  end

  defp admit_completed_alias(%{queue: nil} = opts), do: opts

  defp admit_completed_alias(opts) do
    assert {:ok, queued} = Crawler.crawl(opts.url, opts)
    queued
  end

  defp run_completed_alias(%{queue: nil} = opts, observer) do
    worker = self()
    Crawler.Store.Execution.run_job(opts, &hold_completed_alias(&1, observer, worker))
  end

  defp run_completed_alias(opts, observer) do
    assert {:ok, claim, :fetch, admitted} = Store.checkout_job(opts.queue)
    worker = self()

    assert :ok =
             Crawler.Store.Execution.run(admitted, &hold_completed_alias(&1, observer, worker))

    assert :ok = Store.complete_job(claim, Crawler.Job.Outcome.new(:succeeded))
  end

  defp hold_completed_alias(owned, observer, worker) do
    assert %Crawler.Store.Page{} = page = Crawler.Fetcher.fetch(owned)
    retain_retired_body(owned.fixture_holder, page)

    assert :ok =
             Store.complete_page(
               {page.url, owned.scope},
               owned.generation,
               owned.queue,
               page.opts.alias_url,
               false
             )

    {{landing, scope}, receipt} =
      :sys.get_state(Store).scheduler_workers[owned.scheduler_claim].completed_alias

    send(
      observer,
      {:canonical_alias_completed, worker,
       %{
         worker: worker,
         executor: self(),
         claim: owned.scheduler_claim,
         target: owned.target_handle,
         source: {page.url, scope},
         landing: {landing, scope},
         receipt: receipt,
         body_receipt: page.opts.body_resource
       }}
    )

    receive do
      :finish_completed_alias -> :ok
    end
  end

  defp finish_completed_alias(held) do
    monitor = Process.monitor(held.worker)
    send(held.executor, :finish_completed_alias)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 2_000

    wait(fn ->
      assert %{status: :succeeded} = Store.target_outcome(held.target)
      refute Map.has_key?(:sys.get_state(Store).scheduler_workers, held.claim)
      assert_released([held.receipt])
    end)
  end

  defp retain_retired_body(nil, _page), do: :ok

  defp retain_retired_body(holder, page) do
    receipt = page.opts.body_resource
    assert :ok = Store.retain_resource(receipt, holder)
    assert {:ok, _} = Store.deliver_resource(receipt, holder, page.body)
  end

  defp hold_retired_body(observer) do
    receive do
      {:crawler_resource_delivery, receipt, _lease, _reply, _ref, body} ->
        send(Store, {:crawler_resource_adopted, receipt, self()})
        _ = :sys.get_state(Store)
        send(observer, {:retired_body_held, self(), receipt})

        receive do
          :drop -> byte_size(body)
        end
    end
  end

  defp queued_fallbacks(context, count \\ 3) do
    assert :ok = QueueTickets.attach(context.queue, 1)

    for index <- 1..count do
      context =
        Map.merge(context, %{
          pair_suffix: "/#{index}",
          max_queue_tickets: 1,
          tagged_fallback: true
        })

      rig = retain_fallback(context, :default, &start_completed_source/3, true)
      publish_source(rig, :succeeded)
      finish_landing(rig)
      assert candidate(rig).status == :queued
      rig
    end
  end

  defp assert_queued_ticket(context, rigs) do
    state = :sys.get_state(Store)
    refs = MapSet.new(rigs, & &1.ref)
    assert MapSet.new(Map.keys(state.settlements.candidates)) == refs
    assert MapSet.new(Map.keys(state.settlements.ready[context.queue])) == refs

    assert MapSet.new(Map.keys(state.settlements.pending[{context.scope, context.generation}])) ==
             refs

    assert Enum.all?(state.settlements.candidates, fn {_ref, entry} -> entry.status == :queued end)

    assert Store.pending_count(context.scope) == length(rigs)
    assert Store.inflight_count(context.scope) == 0
    assert %{cap: 1, outstanding: 1} = QueueTickets.status(context.queue)
    paused_ticket(context.queue)
  end

  defp paused_ticket(queue) do
    assert {:paused, %OPQ.Queue{data: data}, _} = OPQ.info(queue)
    assert [%QueueTickets.Ticket{queue: ^queue} = ticket] = :queue.to_list(data)
    ticket
  end

  defp assert_ticket_cap(queue) do
    assert %{cap: 1, outstanding: outstanding} = QueueTickets.status(queue)
    assert outstanding <= 1
    assert {_, %OPQ.Queue{data: data}, _} = OPQ.info(queue)
    assert :queue.len(data) <= 1
    assert Enum.all?(:queue.to_list(data), &match?(%QueueTickets.Ticket{}, &1))
  end

  defp retain_fallback(
         context,
         source_queue \\ :default,
         start_source \\ &SettlementClaimHelpers.start_source/3,
         bind_landing_target? \\ false
       ) do
    source_queue = if source_queue == :default, do: context.queue, else: source_queue
    suffix = context[:pair_suffix] || ""
    source = context.url <> "/settlement/source" <> suffix <> (context[:source_suffix] || "")
    landing = context.url <> "/settlement/landing" <> suffix

    target_opts = target_options(context, landing)

    source_opts = %{target_opts | url: source, queue: source_queue}
    landing_worker = context[:landing_worker] || claim_worker(target_opts, bind_landing_target?)
    source_claim = start_source.(context, source_opts, landing)
    ref = source_claim.ref
    if source_queue, do: assert(is_reference(ref))

    %{
      ref: ref,
      source_claim: source_claim,
      source_opts: source_opts,
      target_opts: target_opts,
      landing: landing,
      landing_worker: landing_worker
    }
  end

  defp target_options(context, landing) do
    %{
      url: landing,
      scope: context.scope,
      generation: context.generation,
      queue: context.queue,
      max_pages: :infinity,
      max_queue_tickets:
        context[:max_queue_tickets] || Crawler.Limits.defaults().max_queue_tickets,
      run_timeout: context[:run_timeout] || Crawler.Limits.defaults().run_timeout,
      javascript_goal: context[:javascript_goal] || :script,
      store: Store
    }
  end

  defp finish_source(rig), do: SettlementClaimHelpers.finish_source(rig.source_claim)

  defp start_completed_source(context, opts, landing) do
    ReqTestSite.expect_once(context.site, "GET", URI.parse(opts.url).path, fn conn ->
      conn |> Plug.Conn.put_resp_header("location", landing) |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect_once(context.site, "GET", URI.parse(landing).path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.resp(200, context[:source_body] || "FALLBACK")
    end)

    opts =
      Map.merge(opts, %{
        req_options: context.req_options,
        respect_robots: false,
        retries: 0,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        store: ObservedStore,
        observer: self(),
        landing_url: landing,
        hold_fallback: context[:hold_fallback] || false,
        tagged_fallback: context[:tagged_fallback] || false,
        fallback_error: context[:fallback_error],
        attempt_timeout: context[:attempt_timeout] || Crawler.Limits.defaults().attempt_timeout
      })

    assert {:ok, queued} = Crawler.crawl(opts.url, opts)
    observer = self()

    worker =
      spawn(fn ->
        assert {:ok, claim, :fetch, admitted} = Store.checkout_job(queued.queue)
        source_worker = self()

        retained =
          Crawler.Store.Execution.run(admitted, fn owned ->
            assert %Crawler.Store.Page{} = page = Crawler.Fetcher.fetch(owned)
            maybe_share_candidate_page(context, page, owned)

            retained = %{ref: page.opts.alias_candidate, target: owned.target_handle}
            maybe_hold_source(context, observer, retained, source_worker)

            assert :ok =
                     Store.complete_page(
                       {page.url, owned.scope},
                       owned.generation,
                       owned.queue,
                       nil,
                       false
                     )

            retained
          end)

        send(observer, {:completed_source, self(), retained})

        receive do
          {:publish_source, status} ->
            assert :ok =
                     Store.complete_job(claim, Crawler.Job.Outcome.new(status, :fixture_finished))

            send(observer, {:source_published, self()})
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    phase = if context[:defer_source_completion], do: :retained_source, else: :completed_source
    assert_receive {^phase, ^worker, retained}, 2_000
    Map.put(retained, :worker, worker)
  end

  defp maybe_share_candidate_page(%{share_candidate_page: true}, page, owned) do
    [receipt] = :sys.get_state(Store).settlements.candidates[page.opts.alias_candidate].resources
    opts = page.opts |> Map.put(:page_resource, receipt) |> Map.put(:body_resource, nil)
    assert :stored = Store.add_page_data({page.url, owned.scope}, page.body, opts)
  end

  defp maybe_share_candidate_page(_context, _page, _owned), do: :ok

  defp maybe_hold_source(%{defer_source_completion: true}, observer, retained, source_worker) do
    send(observer, {:retained_source, source_worker, Map.put(retained, :executor, self())})

    receive do
      :complete_source -> :ok
    end
  end

  defp maybe_hold_source(_context, _observer, _retained, _source_worker), do: :ok

  defp complete_deferred_source(rig, :both_retained_before_completion) do
    worker = rig.source_claim.worker
    send(rig.source_claim.executor, :complete_source)
    assert_receive {:completed_source, ^worker, _retained}, 2_000
  end

  defp complete_deferred_source(_rig, :completed_before_second_retained), do: :ok

  defp assert_fallback_result(:attempt_timeout) do
    assert_receive {:fallback_started, callback}, 2_000
    monitor = Process.monitor(callback)
    assert_receive {:DOWN, ^monitor, :process, ^callback, _reason}, 2_000
  end

  defp assert_fallback_result(:resource_limit) do
    assert_receive {:fallback_stored, "FALLBACK"}, 2_000
  end

  defp publish_source(rig, status) do
    worker = rig.source_claim.worker
    monitor = Process.monitor(worker)
    send(worker, {:publish_source, status})
    assert_receive {:source_published, ^worker}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
  end

  defp source_outcome(rig) do
    :sys.get_state(Store).scheduler.frontier.jobs[rig.source_claim.target].outcome
  end

  defp assert_released(receipts) do
    state = :sys.get_state(Store)

    for receipt <- receipts do
      refute Map.has_key?(state.persistent_counts, receipt)
      refute MapSet.member?(state.persistent_resources, receipt)
      refute Map.has_key?(state.resources.receipts, receipt)
    end
  end

  defp finish_landing(rig), do: finish_worker(rig.landing_worker)

  defp claim_worker(opts, bind_target? \\ false, local_completion? \\ false) do
    opts =
      opts
      |> Map.merge(%{max_body: 1_024, max_analysis_bytes: 2_097_152, respect_robots: false})
      |> Crawler.Options.assign_defaults()

    assert {:ok, prepared} = Crawler.Fetcher.Requester.prepare(opts)
    assert {:ok, _admitted} = Store.admit_job(opts, prepared)
    observer = self()

    worker =
      spawn(fn ->
        {:ok, claim, :fetch, admitted} =
          wait(fn -> assert {:ok, _, :fetch, _} = Store.checkout_job(opts.queue) end)

        claimant = self()

        assert :ok =
                 Crawler.Store.Execution.run(admitted, fn owned ->
                   target = if bind_target?, do: owned.target_handle

                   case Store.add(
                          {owned.url, owned.scope},
                          owned.generation,
                          owned.queue,
                          nil,
                          target
                        ) do
                     {:ok, _} -> :ok
                     {:error, {:already_registered, _}} -> :ok
                   end

                   hold_landing_completion(local_completion?, owned, observer, claimant)
                 end)

        unless local_completion?, do: send(observer, {:claimed, self()})

        receive do
          {:finish, status} ->
            assert :ok =
                     Store.complete_job(claim, Crawler.Job.Outcome.new(status, :fixture_finished))

            send(observer, {:finished, self(), claim})

          :finish ->
            Store.complete_job(claim, Crawler.Job.Outcome.new(:failed, :fixture_finished))
            send(observer, {:finished, self(), claim})

          :complete ->
            Store.complete_job(claim, Crawler.Job.Outcome.new(:failed, :fixture_finished))
            send(observer, {:completed, self(), claim})

            receive do
              :exit -> :ok
            end
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)

    if local_completion? do
      assert_receive {:claimed, ^worker, executor, target}, 2_000
      %{worker: worker, executor: executor, target: target}
    else
      assert_receive {:claimed, ^worker}, 2_000
      worker
    end
  end

  defp hold_landing_completion(true, owned, observer, claimant) do
    assert %Crawler.Store.Page{body: "LANDING"} = Crawler.Fetcher.fetch(owned)
    send(observer, {:claimed, claimant, self(), owned.target_handle})

    receive do
      :complete_landing ->
        assert :ok =
                 Store.complete_page(
                   {owned.url, owned.scope},
                   owned.generation,
                   owned.queue,
                   nil,
                   false
                 )

        send(observer, {:landing_completed, claimant})
        :ok
    end
  end

  defp hold_landing_completion(false, _owned, _observer, _claimant), do: :ok

  defp maybe_complete_landing(local, order, phase)
       when {order, phase} in [
              {:retained_before_landing_completion, :after_retention},
              {:retained_after_landing_completion, :before_retention}
            ] do
    send(local.executor, :complete_landing)
    worker = local.worker
    assert_receive {:landing_completed, ^worker}, 2_000
  end

  defp maybe_complete_landing(_local, _order, _phase), do: :ok

  defp finish_local_landing(local, status) do
    worker = local.worker
    monitor = Process.monitor(worker)
    send(worker, {:finish, status})
    assert_receive {:finished, ^worker, claim}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    wait(fn -> refute Map.has_key?(:sys.get_state(Store).scheduler_workers, claim) end)
  end

  defp assert_landing_result(:succeeded, rig) do
    await_idle(rig.source_opts)
    refute_receive {:fallback_stored, _}
    state = :sys.get_state(Store)
    run = state.scheduler.frontier.runs[{rig.source_opts.scope, rig.source_opts.generation}]
    assert run.groups[rig.source_opts.url].succeeded?
    assert run.groups[rig.landing].succeeded?
    assert Store.ops_count(rig.source_opts.scope) == 2
  end

  defp assert_landing_result(_status, rig) do
    assert_receive {:fallback_stored, "FALLBACK"}, 2_000
    await_idle(rig.source_opts)
    refute_receive {:fallback_stored, _}
    assert Store.ops_count(rig.source_opts.scope) == 1
  end

  defp finish_worker(worker) do
    monitor = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:finished, ^worker, claim}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    wait(fn -> refute Map.has_key?(:sys.get_state(Store).scheduler_workers, claim) end)
  end

  defp candidate(rig), do: :sys.get_state(Store).settlements.candidates[rig.ref]

  defp assert_idle(scope) do
    assert Store.inflight_count(scope) == 0
    assert Store.pending_count(scope) == 0
    assert :sys.get_state(Store).settlements.candidates == %{}
    assert :sys.get_state(Store).settlements.ready == %{}
    assert :sys.get_state(Store).settlements.pending == %{}
  end
end
