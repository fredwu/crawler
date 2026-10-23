defmodule Crawler.Phase2.SourceManagerTest do
  use ExUnit.Case, async: false

  alias Crawler.Fetcher
  alias Crawler.Store
  alias Crawler.Store.Execution
  alias Crawler.Store.Page
  alias Crawler.Store.Resources
  alias Crawler.Store.Retained

  setup do
    Req.Test.set_req_test_to_shared()
    scope = make_ref()

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, "<p>source cache</p>")
    end)

    on_exit(fn ->
      Store.dispose_scope(scope)

      assert eventually(fn ->
               not Enum.any?(:sys.get_state(Store).source_cache_run_bytes, fn {{owner, _}, _} ->
                 owner === scope
               end)
             end)

      Req.Test.set_req_test_to_private()
    end)

    %{scope: scope}
  end

  test "publication adopts a funded entry and replay creates current independent credit", c do
    parent = self()

    assert :ok =
             Execution.run_job(options(c), fn owned ->
               assert %Page{analysis: analysis} = page = source_page(owned)

               assert {:compute, token} =
                        Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

               assert :ok = Store.publish_analysis(page.opts, token, analysis, :borrowed)
               state = :sys.get_state(Store)
               run = {owned.scope, owned.generation}
               assert map_size(source_caches(state, run)) == 1
               assert map_size(cache_resources(state, run)) == 1
               refute Map.has_key?(state.source_cache_leases, owned.execution_lease)
               send(parent, {:publication, owned.execution_lease, run})

               assert {:cached, cached, credit} =
                        Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

               assert cached === analysis
               assert credit.root_ownership == :borrowed
               assert [retained] = credit.retained
               assert [backing] = credit.backing
               state = :sys.get_state(Store)
               assert state.resources.receipts[retained].lease == owned.execution_lease
               assert state.resources.receipts[backing].lease == owned.execution_lease
               refute Map.has_key?(state.source_cache_resources, retained)
               refute Map.has_key?(state.source_cache_resources, backing)
               :ok
             end)

    assert_receive {:publication, lease, run}
    assert eventually(fn -> execution_closed?(:sys.get_state(Store), lease) end)

    state = :sys.get_state(Store)
    assert Map.fetch!(state.source_cache_run_bytes, run) > 0
    assert state.source_cache_workspace > 0
    assert map_size(cache_resources(state, run)) == 1
    Store.dispose_scope(c.scope)

    assert eventually(fn ->
             state = :sys.get_state(Store)

             source_caches(state, run) == %{} and
               Map.get(state.source_cache_run_bytes, run, 0) == 0 and
               cache_resources(state, run) == %{}
           end)
  end

  test "a malformed publication token does not publish or retain its transport grant", c do
    assert :ok =
             Execution.run_job(options(c), fn owned ->
               assert %Page{analysis: analysis} = page = source_page(owned)

               assert {:compute, token} =
                        Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

               assert {:error, :stale_token} =
                        Store.publish_analysis(page.opts, :malformed, analysis, :borrowed)

               assert :ok = Store.publish_analysis(page.opts, token, analysis, :borrowed)
               assert Process.alive?(Process.whereis(Store))
               :ok
             end)
  end

  test "an import that cannot fund its second receipt does not publish partial ledger effects",
       c do
    assert :ok =
             Execution.run_job(options(c), fn owned ->
               assert %Page{analysis: analysis} = page = source_page(owned)

               assert {:compute, token} =
                        Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

               assert :ok = Store.publish_analysis(page.opts, token, analysis, :borrowed)
               {request, incoming} = funded_acquire(page.opts, analysis.lexical_key)
               state = :sys.get_state(Store)
               [copy] = Map.keys(cache_resources(state, {owned.scope, owned.generation}))
               entry = entry(page.opts, analysis, copy)
               {:ok, copied} = Retained.copy_bytes(entry, owned.max_retained_bytes)
               bytes = copied + analysis.allocation.retained + 4096
               arena = state.executions[owned.execution_lease].arena

               {{:ok, _}, virtual, _} =
                 Resources.reserve(
                   state.resources,
                   arena,
                   owned.execution_lease,
                   :analysis,
                   bytes,
                   Process.whereis(Store)
                 )

               first = state.resources.arenas[arena].free - virtual.arenas[arena].free
               blocker = leave_capacity(owned, first + 128)
               before = receipt_refs(:sys.get_state(Store), owned.execution_lease)
               worker = self()
               assert {:error, {:limit, :arena_capacity}} = owner_call(owned, request)
               Store.release_resource(incoming)
               Store.release_resource(blocker)
               assert eventually(fn -> workspaces_released?(:sys.get_state(Store), worker) end)
               after_refs = receipt_refs(:sys.get_state(Store), owned.execution_lease)
               assert MapSet.subset?(after_refs, before)

               assert {:cached, _, _} =
                        Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

               :ok
             end)
  end

  test "a transfer failure releases workspace adopted before the failed cache creation", c do
    assert :ok =
             Execution.run_job(options(c), fn owned ->
               assert %Page{analysis: analysis} = page = source_page(owned)
               baseline = :sys.get_state(Store)
               run = {owned.scope, owned.generation}
               assert source_caches(baseline, run) == %{}
               {request, incoming} = funded_acquire(page.opts, analysis.lexical_key)
               state = :sys.get_state(Store)
               arena = state.executions[owned.execution_lease].arena
               workspace_bytes = max(98_304 - state.source_cache_workspace, 0)

               workspace =
                 if workspace_bytes == 0 do
                   0
                 else
                   {{:ok, _}, virtual, _} =
                     Resources.reserve(
                       state.resources,
                       arena,
                       owned.execution_lease,
                       :scratch,
                       workspace_bytes,
                       Process.whereis(Store)
                     )

                   state.resources.arenas[arena].free - virtual.arenas[arena].free
                 end

               blocker = leave_capacity(owned, workspace + 128)
               worker = self()
               assert {:error, {:limit, :arena_capacity}} = owner_call(owned, request)
               Store.release_resource(incoming)
               Store.release_resource(blocker)
               assert eventually(fn -> workspaces_released?(:sys.get_state(Store), worker) end)
               state = :sys.get_state(Store)
               assert source_caches(state, run) == source_caches(baseline, run)
               assert state.source_cache_bytes == baseline.source_cache_bytes
               assert state.source_cache_workspace == baseline.source_cache_workspace
               assert Map.get(state.source_cache_run_bytes, run, 0) == 0

               assert {:compute, _} =
                        Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

               :ok
             end)
  end

  test "a later executor preserves the converted root seed and adopts fresh current receipts",
       c do
    parent = self()

    body =
      <<255, 254>> <> :unicode.characters_to_binary("<p>converted</p>", :utf8, {:utf16, :little})

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :physical_request)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-16")
      |> Plug.Conn.resp(200, body)
    end)

    assert :ok =
             Execution.run_job(Map.put(options(c), :style_group, :first), fn owned ->
               assert %Page{analysis: analysis} = page = source_page(owned)
               assert analysis.allocation.seed.retained > 0

               assert {:compute, token} =
                        Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

               assert :ok = Store.publish_analysis(page.opts, token, analysis, :retained)
               send(parent, {:original, self(), owned.execution_lease, analysis.allocation.seed})
               :ok
             end)

    assert_receive {:original, producer, original_lease, seed}
    refute Process.alive?(producer)
    assert_receive :physical_request

    assert :ok =
             Execution.run_job(Map.put(options(c), :style_group, :second), fn owned ->
               assert owned.scheduler_mode == :interpret
               assert %Page{analysis: analysis} = page = source_page(owned)

               assert {:cached, cached, credit} =
                        Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

               assert cached.allocation.seed === seed
               normalized = Map.merge(page.opts, Map.new(Crawler.Limits.analysis(page.opts)))
               assert {:ok, adopted} = Crawler.Analysis.cached_result(cached, normalized, seed)
               assert adopted.budget.peak >= seed.peak

               refute match?(
                        {:ok, _},
                        Crawler.Analysis.cached_result(
                          cached,
                          normalized,
                          Crawler.Analysis.Budget.new(cached.limits)
                        )
                      )

               assert credit.root_ownership == :borrowed
               state = :sys.get_state(Store)

               for receipt <- credit.retained ++ credit.backing do
                 assert state.resources.receipts[receipt].lease === owned.execution_lease
                 refute state.resources.receipts[receipt].lease === original_lease
               end

               :ok
             end)

    refute_receive :physical_request
  end

  test "producer death wakes an indexed waiter to compute under its existing target", c do
    parent = self()
    base = Map.put(options(c), :max_representations, 1)

    producer =
      Task.async(fn ->
        try do
          Execution.run_job(Map.put(base, :style_group, :producer), fn owned ->
            assert %Page{analysis: analysis} = page = source_page(owned)

            assert {:compute, _} =
                     Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

            send(
              parent,
              {:producer, self(), page.source_revision, owned.execution_lease,
               {owned.scope, owned.generation}}
            )

            receive do
              :finish -> :ok
            end
          end)
        catch
          :exit, _ -> :producer_down
        end
      end)

    assert_receive {:producer, executor, source, producer_lease, run}, 2000

    waiter =
      Task.async(fn ->
        Execution.run_job(Map.put(base, :style_group, :waiter), fn owned ->
          assert %Page{analysis: analysis} = page = source_page(owned)

          assert {:waiting, _} =
                   Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

          target = owned.target_handle
          lease = owned.execution_lease
          send(parent, {:waiting, target, lease})

          receive do
            {:crawler_source_cache, ^source, ^target, ^lease, :retry} -> :ok
          after
            2000 -> flunk("the retired producer did not wake its waiter")
          end

          assert {:compute, token} =
                   Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

          assert elem(token, 2) === target
          assert :ok = Store.publish_analysis(page.opts, token, analysis, :borrowed)
          send(parent, {:replaced, target})
          :ok
        end)
      end)

    assert_receive {:waiting, target, waiter_lease}, 2000
    Process.exit(executor, :kill)
    assert Task.await(producer, 5000) == :producer_down
    assert Task.await(waiter, 5000) == :ok
    assert_receive {:replaced, ^target}
    state = :sys.get_state(Store)
    assert map_size(representations(state, run)) == 1

    assert eventually(fn ->
             state = :sys.get_state(Store)

             not Map.has_key?(state.source_cache_leases, producer_lease) and
               not Map.has_key?(state.source_cache_leases, waiter_lease)
           end)

    assert Store.target_outcome(target).status == :succeeded
  end

  test "new lexical modes borrow only an exactly matching decoded-source capsule", c do
    parent = self()
    text = "let value = '" <> String.duplicate("x", 100) <> "';"
    body = <<255, 254>> <> :unicode.characters_to_binary(text, :utf8, {:utf16, :little})

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/javascript; charset=utf-16")
      |> Plug.Conn.resp(200, body)
    end)

    assert :ok =
             Execution.run_job(Map.put(options(c), :javascript_goal, :script), fn owned ->
               assert %Page{analysis: analysis} = page = source_page(owned)

               assert {:compute, token} =
                        Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

               assert :ok = Store.publish_analysis(page.opts, token, analysis, :retained)
               assert {:decode, root_token} = Store.acquire_decoded(page.opts, make_ref())

               assert :ok =
                        Store.publish_decoded(
                          page.opts,
                          root_token,
                          page.body,
                          page.credit.decoder_checkpoint,
                          :retained
                        )

               send(parent, {:decoded_source, page.source_revision, analysis.allocation.seed})
               :ok
             end)

    assert_receive {:decoded_source, revision, seed}

    assert :ok =
             Execution.run_job(Map.put(options(c), :javascript_goal, :module), fn owned ->
               assert %Page{analysis: analysis} = page = source_page(owned)

               assert {:decoded, root} = Store.acquire_decoded(page.opts, make_ref())

               assert {:compute, token} =
                        Store.acquire_analysis(page.opts, analysis.lexical_key, make_ref())

               assert elem(token, 0) === revision
               assert root.source_revision === revision
               assert root.body == text
               assert root.decoder_seed === seed
               assert root.root_ownership == :borrowed
               assert root.original_root_ownership == :retained
               assert root.decode_context === Map.take(page.opts, [:content_type, :headers])
               assert [receipt] = root.credit.backing
               state = :sys.get_state(Store)
               assert state.resources.receipts[receipt].lease === owned.execution_lease

               assert {:ok, copied} =
                        Retained.copy_bytes({:decoded, root}, owned.max_retained_bytes)

               assert state.resources.receipts[receipt].copy_bytes >= copied

               headers = page.opts.headers ++ [{"x-decode-context", "different"}]
               other_opts = Map.put(page.opts, :headers, headers)

               assert {:error, :incompatible_decode_context} =
                        Store.acquire_decoded(other_opts, make_ref())

               :ok
             end)
  end

  defp source_caches(state, run) do
    Map.filter(state.source_caches, fn {_revision, row} -> row.run === run end)
  end

  defp cache_resources(state, run) do
    Map.filter(state.source_cache_resources, fn {receipt, _count} ->
      Map.fetch!(state.resources.receipts, receipt).run === run
    end)
  end

  defp representations(state, run) do
    ids = Map.get(state.scheduler.run_representations, run, %{members: %{}}).members
    Map.take(state.scheduler.representations, Map.keys(ids))
  end

  defp receipt_refs(state, lease) do
    for {ref, %{lease: ^lease}} <- state.resources.receipts, into: MapSet.new(), do: ref
  end

  defp workspaces_released?(state, worker) do
    not Enum.any?(state.source_cache_workspaces, fn {_ref, owner} -> owner === worker end)
  end

  defp execution_closed?(state, lease) do
    not Map.has_key?(state.executions, lease) and
      not Enum.any?(state.resources.arenas, fn {_id, arena} ->
        arena.lease === lease and arena.open?
      end)
  end

  defp source_page(owned) do
    {:ok, response} = Fetcher.control_request(owned)
    opts = Crawler.Fetcher.HeaderPreparer.prepare(Req.get_headers_list(response), owned)
    revision = Req.Response.get_private(response, :crawler_source_revision)
    opts = Map.put(opts, :source_revision, revision)
    limits = Map.new(Crawler.Limits.analysis(opts))

    {:ok, receipt, capacity} =
      Store.reserve_resource_up_to(
        opts,
        :analysis,
        opts.max_analysis_bytes,
        Process.whereis(Store)
      )

    {:ok, seed} =
      Crawler.Analysis.Budget.charge(
        Crawler.Analysis.Budget.new(limits),
        opts.max_analysis_bytes - capacity
      )

    {:ok, body, seed, _ownership} = Crawler.Charset.decode_owned_result(response.body, opts, seed)
    {:ok, analysis} = Crawler.Analysis.analyze(body, Map.merge(opts, limits), seed)

    :ok =
      Store.commit_resource(
        receipt,
        analysis.budget.retained - (opts.max_analysis_bytes - capacity)
      )

    %Page{
      url: opts.url,
      body: body,
      opts: opts,
      analysis: analysis,
      source_revision: revision,
      target_handle: opts.target_handle,
      credit: %{
        decoder_checkpoint: %{budget: seed, unavailable: opts.max_analysis_bytes - capacity}
      }
    }
  end

  defp funded_acquire(opts, key) do
    context =
      Map.take(opts, [
        :scope,
        :generation,
        :queue,
        :execution_lease,
        :scheduler_claim,
        :target_handle,
        :representation_id,
        :source_revision,
        :content_type,
        :headers,
        :max_interpretations,
        :max_pending,
        :max_frontier_bytes,
        :max_analysis_bytes,
        :max_body,
        :max_retained_bytes
      ])
      |> Map.put(:analysis_limits, Map.new(Crawler.Limits.analysis(opts)))

    command = {:acquire, key, make_ref(), make_ref()}
    {:ok, bytes} = Retained.bytes({:source_cache, context, command}, opts.max_retained_bytes)

    {:ok, copied} =
      Retained.copy_bytes({:source_cache, context, command}, opts.max_retained_bytes)

    {:ok, receipt} =
      Store.reserve_resource(opts, :response, max(bytes, copied), Process.whereis(Store))

    :ok = Store.commit_response_resource(receipt, max(bytes, copied), copied)
    {{:source_cache, context, put_elem(command, 3, receipt)}, receipt}
  end

  defp entry(opts, analysis, copy),
    do: %{
      source_revision: opts.source_revision,
      lexical_key: analysis.lexical_key,
      analysis: analysis,
      root_ownership: :borrowed,
      retained_receipts: [],
      backing_receipts: [],
      copy_receipt: copy
    }

  defp leave_capacity(opts, bytes) do
    state = :sys.get_state(Store)
    arena = state.executions[opts.execution_lease].arena
    free = state.resources.arenas[arena].free

    {{:ok, _}, virtual, _} =
      Resources.reserve(state.resources, arena, opts.execution_lease, :scratch, 0, self())

    overhead = free - virtual.arenas[arena].free
    {:ok, blocker} = Store.reserve_resource(opts, :scratch, free - bytes - overhead)
    blocker
  end

  defp owner_call(opts, request),
    do: GenServer.call(Store, {:execution, opts.execution_lease, request})

  defp options(c) do
    %{
      url: "https://source-cache.test/document",
      scope: c.scope,
      html_tag: "a",
      store: nil,
      respect_robots: false,
      retries: 0,
      interval: 0,
      max_body: 1024,
      max_analysis_bytes: 1_048_576,
      max_interpretations: 8,
      max_pending: 8,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
  end

  defp eventually(callback, attempts \\ 500)
  defp eventually(callback, 0), do: callback.()

  defp eventually(callback, attempts) do
    if callback.() do
      true
    else
      Process.sleep(10)
      eventually(callback, attempts - 1)
    end
  end
end
