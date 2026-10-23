defmodule Crawler.Phase2.DecodedSourceManagerTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.Fetcher
  alias Crawler.Fetcher.HeaderPreparer
  alias Crawler.Store
  alias Crawler.Store.Execution
  alias Crawler.Store.Retained

  setup do
    Req.Test.set_req_test_to_shared()
    scope = make_ref()
    parent = self()

    body =
      <<255, 254>> <>
        :unicode.characters_to_binary("<svg><title>root</title></svg>", :utf8, {:utf16, :little})

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :physical_request)
      conn |> Plug.Conn.put_resp_content_type("image/svg+xml") |> Plug.Conn.resp(200, body)
    end)

    on_exit(fn ->
      Store.dispose_scope(scope)

      assert eventually(fn ->
               state = :sys.get_state(Store)

               not Enum.any?(state.source_cache_run_bytes, fn {{owner, _}, _} ->
                 owner === scope
               end)
             end)

      Req.Test.set_req_test_to_private()
    end)

    %{scope: scope}
  end

  test "an opaque decoded root survives its producer without allocating a lexical slot", c do
    parent = self()

    assert :ok =
             Execution.run_job(options(c, :opaque), fn owned ->
               {response, opts} = source(owned)
               assert {:decode, token} = Store.acquire_decoded(opts, make_ref())
               {body, checkpoint, ownership} = decode(response.body, opts)
               assert ownership == :retained
               assert :ok = Store.publish_decoded(opts, token, body, checkpoint, ownership)
               state = :sys.get_state(Store)
               row = state.source_caches[opts.source_revision]
               assert :gb_trees.is_empty(row.cache.slots)
               assert :gb_trees.is_empty(row.cache.waiters)
               assert row.decoded.status == :ready
               assert map_size(cache_resources(state, c.scope)) == 1

               send(
                 parent,
                 {:original, self(), opts.source_revision, checkpoint, body,
                  owned.execution_lease}
               )

               :ok
             end)

    assert_receive {:original, producer, revision, checkpoint, body, lease}
    refute Process.alive?(producer)
    assert_receive :physical_request
    assert eventually(fn -> leases_released?([lease]) end)

    assert :ok =
             Execution.run_job(options(c, :interpreted), fn owned ->
               assert owned.scheduler_mode == :interpret
               {_response, opts} = source(owned)
               assert {:decoded, root} = Store.acquire_decoded(opts, make_ref())
               assert root.source_revision === revision
               assert root.body === body
               assert root.decoder_seed === checkpoint.budget
               assert root.unavailable === checkpoint.unavailable
               assert root.root_ownership == :borrowed
               assert root.original_root_ownership == :retained
               assert root.credit.unavailable === checkpoint.budget.retained
               assert root.credit.retained == []
               assert [receipt] = root.credit.backing
               record = :sys.get_state(Store).resources.receipts[receipt]
               assert record.lease === owned.execution_lease
               assert {:ok, bytes} = Retained.bytes({:decoded, root}, owned.max_retained_bytes)

               assert {:ok, copy} =
                        Retained.copy_bytes({:decoded, root}, owned.max_retained_bytes)

               assert record.actual >= max(bytes, copy)
               assert record.copy_bytes >= copy

               assert :gb_trees.is_empty(
                        :sys.get_state(Store).source_caches[revision].cache.slots
                      )

               :ok
             end)

    refute_receive :physical_request
  end

  test "a dead decoder wakes a bounded waiter under the same canonical physical source", c do
    parent = self()

    producer =
      Task.async(fn ->
        try do
          Execution.run_job(options(c, :producer), fn owned ->
            {_response, opts} = source(owned)
            assert {:decode, _} = Store.acquire_decoded(opts, make_ref())
            send(parent, {:decoding, self(), opts.source_revision, owned.execution_lease})

            receive do
              :finish -> :ok
            end
          end)
        catch
          :exit, _ -> :producer_down
        end
      end)

    assert_receive {:decoding, executor, revision, producer_lease}, 2000

    waiter =
      Task.async(fn ->
        Execution.run_job(options(c, :waiter), fn owned ->
          {response, opts} = source(owned)
          attempt = make_ref()
          assert {:waiting, ^attempt} = Store.acquire_decoded(opts, attempt)
          target = owned.target_handle
          lease = owned.execution_lease
          send(parent, {:waiting, target, lease})

          receive do
            {:crawler_decoded_source, ^revision, ^target, ^lease, :retry} -> :ok
          after
            2000 -> flunk("decoder death did not wake its waiter")
          end

          assert {:decode, token} = Store.acquire_decoded(opts, make_ref())
          assert elem(token, 1) === target
          {body, checkpoint, ownership} = decode(response.body, opts)
          assert :ok = Store.publish_decoded(opts, token, body, checkpoint, ownership)
          :ok
        end)
      end)

    assert_receive {:waiting, target, waiter_lease}, 2000
    Process.exit(executor, :kill)
    assert Task.await(producer) == :producer_down
    assert Task.await(waiter) == :ok
    assert Store.target_outcome(target).status == :succeeded
    assert eventually(fn -> leases_released?([producer_lease, waiter_lease]) end)
    assert map_size(representations(:sys.get_state(Store), c.scope)) == 1
    assert_receive :physical_request
    refute_receive :physical_request
  end

  test "lexical producer cleanup preserves a ready decoded cell on the same lease link", c do
    parent = self()

    producer =
      Task.async(fn ->
        try do
          Execution.run_job(options(c, :lexical_producer), fn owned ->
            {response, opts} = source(owned)
            assert {:decode, token} = Store.acquire_decoded(opts, make_ref())
            {body, checkpoint, ownership} = decode(response.body, opts)
            assert :ok = Store.publish_decoded(opts, token, body, checkpoint, ownership)
            analysis = analyze(body, checkpoint.budget, opts)
            assert {:compute, _} = Store.acquire_analysis(opts, analysis.lexical_key, make_ref())
            send(parent, {:lexical_producer, self(), opts.source_revision, owned.execution_lease})

            receive do
              :finish -> :ok
            end
          end)
        catch
          :exit, _ -> :producer_down
        end
      end)

    assert_receive {:lexical_producer, executor, revision, producer_lease}, 2000

    waiter =
      Task.async(fn ->
        Execution.run_job(options(c, :lexical_waiter), fn owned ->
          {_response, opts} = source(owned)
          assert {:decoded, root} = Store.acquire_decoded(opts, make_ref())
          analysis = analyze(root.body, root.decoder_seed, opts)

          assert {:waiting, _} = Store.acquire_analysis(opts, analysis.lexical_key, make_ref())
          target = owned.target_handle
          lease = owned.execution_lease
          send(parent, {:lexical_waiting, lease})

          receive do
            {:crawler_source_cache, ^revision, ^target, ^lease, :retry} -> :ok
          after
            2000 -> flunk("lexical producer death did not wake its waiter")
          end

          assert {:compute, token} =
                   Store.acquire_analysis(opts, analysis.lexical_key, make_ref())

          assert :ok = Store.publish_analysis(opts, token, analysis, :borrowed)
          assert :sys.get_state(Store).source_caches[revision].decoded.status == :ready
          :ok
        end)
      end)

    assert_receive {:lexical_waiting, waiter_lease}, 2000
    Process.exit(executor, :kill)
    assert Task.await(producer) == :producer_down
    assert Task.await(waiter) == :ok
    assert eventually(fn -> leases_released?([producer_lease, waiter_lease]) end)
    state = :sys.get_state(Store)
    assert map_size(cache_resources(state, c.scope)) == 2
    assert map_size(representations(state, c.scope)) == 1
  end

  test "publication checks the canonical checkpoint and rejected pregrants leave the owner live",
       c do
    assert :ok =
             Execution.run_job(options(c, :invalid), fn owned ->
               {response, opts} = source(owned)
               assert {:decode, token} = Store.acquire_decoded(opts, make_ref())
               {body, checkpoint, ownership} = decode(response.body, opts)

               assert {:error, :invalid_decoder_seed} =
                        Store.publish_decoded(
                          opts,
                          token,
                          body,
                          %{checkpoint | budget: %{checkpoint.budget | peak: 0}},
                          ownership
                        )

               assert {:error, :stale_token} =
                        Store.publish_decoded(opts, :malformed, body, checkpoint, ownership)

               assert :ok = Store.publish_decoded(opts, token, body, checkpoint, ownership)

               assert {:error, :already_published} =
                        Store.publish_decoded(opts, token, body, checkpoint, ownership)

               assert Process.alive?(Process.whereis(Store))

               assert {:error, :incompatible_decode_context} =
                        Store.acquire_decoded(
                          Map.update!(opts, :headers, &(&1 ++ [{"x-context", "different"}])),
                          make_ref()
                        )

               :ok
             end)
  end

  test "a function-bearing context is rejected before its environment can be materialized", c do
    assert :ok =
             Execution.run_job(options(c, :function), fn owned ->
               {_response, opts} = source(owned)
               backing = :binary.copy(<<1>>, 1_000_000)
               callback = fn -> backing end
               before = :sys.get_state(Store)
               assert source_caches(before, c.scope) == %{}
               assert cache_resources(before, c.scope) == %{}

               assert {:error, {:limit, :decoded_source_context_term}} =
                        Store.acquire_decoded(
                          Map.put(opts, :headers, [{"x-context", callback}]),
                          make_ref()
                        )

               state = :sys.get_state(Store)
               assert source_caches(state, c.scope) === source_caches(before, c.scope)
               assert cache_resources(state, c.scope) === cache_resources(before, c.scope)
               assert {:decode, _} = Store.acquire_decoded(opts, make_ref())
               :ok
             end)
  end

  defp source_caches(state, scope) do
    Map.filter(state.source_caches, fn {_revision, %{run: {owner, _generation}}} ->
      owner === scope
    end)
  end

  defp cache_resources(state, scope) do
    Map.filter(state.source_cache_resources, fn {receipt, _count} ->
      match?({^scope, _generation}, Map.fetch!(state.resources.receipts, receipt).run)
    end)
  end

  defp representations(state, scope) do
    state.scheduler.run_representations
    |> Enum.flat_map(fn
      {{^scope, _generation}, ring} -> Map.keys(ring.members)
      _entry -> []
    end)
    |> then(&Map.take(state.scheduler.representations, &1))
  end

  defp leases_released?(leases) do
    state = :sys.get_state(Store)
    Enum.all?(leases, &(not Map.has_key?(state.source_cache_leases, &1)))
  end

  defp source(owned) do
    {:ok, response} = Fetcher.control_request(owned)
    opts = HeaderPreparer.prepare(Req.get_headers_list(response), owned)

    opts =
      Map.put(
        opts,
        :source_revision,
        Req.Response.get_private(response, :crawler_source_revision)
      )

    {response, opts}
  end

  defp decode(raw, opts) do
    limits = Map.new(Crawler.Limits.analysis(opts))

    {:ok, receipt, capacity} =
      Store.reserve_resource_up_to(
        opts,
        :analysis,
        opts.max_analysis_bytes,
        Process.whereis(Store)
      )

    unavailable = opts.max_analysis_bytes - capacity
    {:ok, seed} = Budget.charge(Budget.new(limits), unavailable)
    {:ok, body, seed, ownership} = Crawler.Charset.decode_owned_result(raw, opts, seed)
    assert :ok = Store.commit_resource(receipt, seed.retained - unavailable)
    {body, %{budget: seed, unavailable: unavailable}, ownership}
  end

  defp analyze(body, seed, opts) do
    available = Budget.available(seed)

    {:ok, receipt, capacity} =
      Store.reserve_resource_up_to(opts, :analysis, available, Process.whereis(Store))

    {:ok, current} = Budget.charge(seed, available - capacity)
    normalized = Map.merge(opts, Map.new(Crawler.Limits.analysis(opts)))
    {:ok, analysis} = Crawler.Analysis.analyze(body, normalized, current)
    assert :ok = Store.commit_resource(receipt, analysis.budget.retained - current.retained)
    analysis
  end

  defp options(c, group) do
    %{
      url: "https://decoded-source.test/root.svg",
      scope: c.scope,
      html_tag: "img",
      style_group: group,
      store: nil,
      respect_robots: false,
      retries: 0,
      interval: 0,
      max_body: 1024,
      max_analysis_bytes: 1_048_576,
      max_interpretations: 8,
      max_pending: 8,
      max_representations: 1,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
  end

  defp eventually(callback, attempts \\ 500)
  defp eventually(callback, 0), do: callback.()

  defp eventually(callback, attempts) do
    if callback.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(callback, attempts - 1)
        )
  end
end
