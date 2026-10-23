defmodule Crawler.CssSettlementTest do
  use Crawler.TestCase, async: false

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Variables
  alias Crawler.Parser.CssSheets
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution
  alias Crawler.Store.Retained

  test "already-scanned groups preserve opaque identities and settle later definitions" do
    opts = options("css-bundle")
    group = {:srcdoc, opts.url, opts.url, <<1, 2, 3>>}
    source = :crypto.hash(:sha256, "source")

    definitions =
      Variables.sheet(Scanner.analyze(":root{--bg:url(found.png)}"), :definitions, opts.url, 0)

    uses = Variables.sheet(Scanner.analyze("a{background:var(--bg)}"), :uses, opts.url, 1)

    bundle = [
      %{
        style_group: group,
        source_revision: source,
        sheets: Enum.map([definitions, uses], &Map.put(&1, :imports, []))
      }
    ]

    assert {:ok, context} = CssSheets.resolve_groups(opts, bundle)
    assert [%{value: "found.png"}] = context.css_tokens.definitions
    assert context.css_tokens.uses == []
    assert context.css_revision != nil
  end

  test "cached CSS context commits actual output without replacing its retained graph", _c do
    opts = options("css-cached-output")

    assert :ok =
             Execution.run(opts, fn owned ->
               source = "a{background:url(one.png)}"

               sheet =
                 Variables.sheet(Scanner.analyze(source), :root, owned.url, 0)
                 |> Map.put(:imports, [])

               bundle = [
                 %{
                   style_group: owned.style_group,
                   source_revision: :crypto.hash(:sha256, source),
                   sheets: [sheet]
                 }
               ]

               prior = Map.keys(:sys.get_state(Store).resources.receipts)
               assert {:ok, fresh} = CssSheets.resolve_groups(owned, bundle)
               fresh_refs = Map.keys(:sys.get_state(Store).resources.receipts) -- prior
               assert_no_snapshot_owner(owned)

               [fresh_output] =
                 Enum.filter(
                   fresh_refs,
                   &(:sys.get_state(Store).resources.receipts[&1].kind == :scratch)
                 )

               group =
                 :sys.get_state(CssSheets).scopes[{owned.scope, owned.generation}].groups[
                   owned.style_group
                 ]

               assert group.output_receipt == fresh_output
               before = Map.keys(:sys.get_state(Store).resources.receipts)
               assert {:ok, cached} = CssSheets.resolve_groups(owned, bundle)
               assert cached === fresh
               assert_no_snapshot_owner(owned)
               state = :sys.get_state(Store)

               [cached_output] =
                 Enum.filter(
                   Map.keys(state.resources.receipts) -- before,
                   &(state.resources.receipts[&1].kind == :scratch)
                 )

               fresh_receipt = state.resources.receipts[fresh_output]
               cached_receipt = state.resources.receipts[cached_output]
               assert is_integer(fresh_receipt.actual)
               assert is_integer(cached_receipt.actual)
               assert cached_receipt.actual < cached_receipt.capacity
               assert {:ok, bytes} = Retained.bytes(cached, cached_receipt.actual)
               assert bytes <= cached_receipt.actual
               assert Authority.resource_current?(cached_output, owned.execution_lease, self())

               current =
                 :sys.get_state(CssSheets).scopes[{owned.scope, owned.generation}].groups[
                   owned.style_group
                 ]

               assert current.output_receipt === fresh_output
               assert current.outcome === group.outcome
               :ok
             end)
  end

  defp assert_no_snapshot_owner(opts) do
    refute Enum.any?(:sys.get_state(Store).resources.receipts, fn {_ref, receipt} ->
             receipt.kind == :css_snapshot and receipt.lease == opts.execution_lease and
               Map.has_key?(receipt.holders, self())
           end)
  end

  test "an admitted graph executes outside the cache and an unrelated scope can progress" do
    opts = options("css-held")
    observer = self()

    task =
      Task.async(fn ->
        Execution.run(opts, fn owned ->
          snapshot = stage(owned, "a{background:var(--missing,url(held.png))}")
          assert {:ok, :compute} = Store.schedule_css(owned, owned.style_group, snapshot.revision)
          send(observer, {:held_snapshot, self(), snapshot.revision, snapshot.snapshot_receipt})
          receive do: (:release -> :ok)
          finish(snapshot, owned)
        end)
      end)

    assert_receive {:held_snapshot, executor, _revision, _receipt}, 2_000
    refute executor == Process.whereis(CssSheets)
    other = options("css-other")

    assert [%{value: "other.png"}] =
             CssParser.spans("a{background:var(--none,url(other.png))}", other)

    send(executor, :release)
    assert Task.await(task, 2_000) == :ok
  end

  test "the managed resolver calls the graph from its admitted executor" do
    opts = options("css-graph-process")
    observer = self()
    :erlang.trace_pattern({Variables, :analyze_result, 4}, true, [:local])

    try do
      assert {:ok, _context} =
               Execution.run(opts, fn owned ->
                 :erlang.trace(self(), true, [:call, {:tracer, observer}])

                 sheet =
                   Variables.sheet(
                     Scanner.analyze("a{background:var(--missing,url(trace.png))}"),
                     :root,
                     owned.url,
                     0
                   )
                   |> Map.put(:imports, [])

                 CssSheets.resolve_groups(owned, [
                   %{
                     style_group: owned.style_group,
                     source_revision: :crypto.hash(:sha256, "trace"),
                     sheets: [sheet]
                   }
                 ])
               end)

      assert_receive {:trace, executor, :call,
                      {Variables, :analyze_result, [_sheets, _fallbacks, _limits, _budget]}},
                     2_000

      refute executor == Process.whereis(CssSheets)
      refute executor == Process.whereis(Store)
    after
      :erlang.trace_pattern({Variables, :analyze_result, 4}, false, [:local])
    end
  end

  test "a superseded graph leaves one latest settlement and never publishes the old fallback" do
    opts = options("css-coalesced")
    observer = self()

    task =
      Task.async(fn ->
        Execution.run(opts, fn owned ->
          snapshot = stage(owned, "a{background:var(--late,url(old-fallback.png))}")
          assert {:ok, :compute} = Store.schedule_css(owned, owned.style_group, snapshot.revision)
          send(observer, {:held_snapshot, self(), snapshot.revision, snapshot.snapshot_receipt})
          receive do: (:release -> finish(snapshot, owned))
        end)
      end)

    assert_receive {:held_snapshot, executor, first_revision, _receipt}, 2_000
    later = %{opts | url: "https://css.test/tokens/late.css"}

    sheet =
      Variables.sheet(Scanner.analyze(":root{--late:url(final.png)}"), :root, later.url, 0)
      |> Map.put(:imports, [])

    assert {:ok, context} =
             CssSheets.resolve_groups(later, [
               %{
                 style_group: opts.style_group,
                 source_revision: :crypto.hash(:sha256, "late"),
                 sheets: [sheet]
               }
             ])

    assert context.css_tokens.root == []
    key = {{opts.scope, opts.generation}, opts.style_group}
    assert Map.has_key?(:sys.get_state(Store).css_jobs, key)
    assert Enum.count(:sys.get_state(Store).css_jobs, fn {entry, _} -> entry == key end) == 1
    send(executor, :release)
    assert {:superseded, latest} = Task.await(task, 2_000)
    refute latest == first_revision
    cache_key = {opts.scope, opts.generation, opts.style_group}
    wait(2_000, fn -> refute Map.has_key?(:sys.get_state(CssSheets).jobs, cache_key) end)

    group =
      :sys.get_state(CssSheets).scopes[{opts.scope, opts.generation}].groups[opts.style_group]

    assert group.urls == ["https://css.test/dir/final.png"]
    refute Enum.any?(group.urls, &String.contains?(&1, "old-fallback"))
  end

  test "reset terminates the snapshot executor and releases its charge after DOWN" do
    opts = options("css-held-reset")
    observer = self()

    task =
      Task.async(fn ->
        Execution.run(opts, fn owned ->
          snapshot = stage(owned, "a{background:var(--missing,url(retained.png))}")
          assert {:ok, :compute} = Store.schedule_css(owned, owned.style_group, snapshot.revision)
          send(observer, {:held_snapshot, self(), snapshot.revision, snapshot.snapshot_receipt})
          receive do: (:release -> finish(snapshot, owned))
        end)
      end)

    assert_receive {:held_snapshot, executor, _revision, receipt}, 2_000
    monitor = Process.monitor(executor)
    assert record = receipt_record(receipt)
    assert Map.has_key?(record.holders, executor)
    Store.drop_scope(opts.scope)
    refute Authority.current?(opts.scope, opts.generation, nil)
    assert Task.await(task, 2_000) == {:error, :stale}
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}
    wait(2_000, fn -> assert receipt_record(receipt) == nil end)
  end

  test "queued registration backing remains charged after producer death until the cache consumes it" do
    opts = options("css-queued-backing")
    cache = Process.whereis(CssSheets)
    :sys.suspend(cache)
    on_exit(fn -> if Process.alive?(cache), do: :sys.resume(cache) end)
    observer = self()

    caller =
      spawn(fn ->
        Execution.run(opts, fn owned ->
          prepared = prepared(owned, "a{background:var(--missing,url(queued.png))}")
          {:ok, facts} = Store.reserve_resource(owned, :css_facts, prepared.bytes, cache)

          {:ok, snapshot} =
            Store.reserve_resource(owned, :css_snapshot, 4 * prepared.bytes, cache)

          {:ok, output} =
            Store.reserve_resource(
              owned,
              :scratch,
              4 * prepared.bytes + 128 * owned.max_css_work,
              cache
            )

          :ok = Store.retain_resource(facts, Process.whereis(Store))
          owned = Map.put(owned, :css_obligation_receipt, facts)

          {:ok, delivery} =
            Store.deliver_resource(
              facts,
              cache,
              {:register, owned,
               Map.put(prepared, :capacities, %{
                 snapshot: 4 * prepared.bytes,
                 output: 4 * prepared.bytes + 128 * owned.max_css_work
               }), snapshot, output, :resolve}
            )

          send(observer, {:queued_registration, self(), facts, delivery})
          receive do: (:never -> :ok)
        end)
      end)

    assert_receive {:queued_registration, executor, receipt, delivery}, 2_000
    Process.exit(caller, :kill)
    wait(2_000, fn -> refute Process.alive?(executor) end)

    wait(2_000, fn ->
      record = receipt_record(receipt)
      assert record != nil
      assert record.holders[cache].status == :abandoned
    end)

    {:messages, messages} = Process.info(cache, :messages)

    delivery_index =
      Enum.find_index(messages, fn
        {:crawler_resource_delivery, ^receipt, _, _, ^delivery, _} -> true
        _ -> false
      end)

    abandon_index =
      Enum.find_index(messages, fn
        {:crawler_resource_abandon, ^receipt, _} -> true
        _ -> false
      end)

    assert is_integer(delivery_index)
    assert is_integer(abandon_index)
    assert delivery_index < abandon_index
    :sys.resume(cache)
    wait(2_000, fn -> assert receipt_record(receipt) == nil end)
    refute Map.has_key?(:sys.get_state(CssSheets).scopes, {opts.scope, opts.generation})

    refute Map.has_key?(
             :sys.get_state(CssSheets).jobs,
             {opts.scope, opts.generation, opts.style_group}
           )
  end

  test "cache death releases only cache holders and leaves Store and unrelated queues alive" do
    opts = options("css-cache-down")
    observer = self()

    task =
      Task.async(fn ->
        Execution.run(opts, fn owned ->
          snapshot = stage(owned, "a{background:var(--missing,url(retained.png))}")
          send(observer, {:held_snapshot, self(), snapshot.revision, snapshot.snapshot_receipt})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:held_snapshot, executor, _revision, receipt}, 2_000
    store = Process.whereis(Store)
    cache = Process.whereis(CssSheets)
    assert :ok = Supervisor.terminate_child(Crawler, CssSheets)
    assert Process.whereis(Store) == store
    assert Process.alive?(executor)
    assert Map.has_key?(receipt_record(receipt).holders, executor)
    assert {:ok, restarted} = Supervisor.restart_child(Crawler, CssSheets)
    refute cache == restarted
    send(executor, :release)
    assert Task.await(task, 2_000) == :ok
    wait(2_000, fn -> assert receipt_record(receipt) == nil end)
  end

  test "cached emission metadata remains charged after its producer exits" do
    opts = options("css-emission-charge")
    body = "a{background:var(--missing,url(emitted.png))}"

    assert {:ok, [%{value: "emitted.png"}]} =
             CssSheets.remember(opts, body, Scanner.analyze(body))

    assert ["https://css.test/dir/emitted.png"] = CssSheets.take_urls(opts, body, [])
    cache = Process.whereis(CssSheets)
    group = :sys.get_state(cache).scopes[{opts.scope, opts.generation}].groups[opts.style_group]
    assert [receipt] = Map.keys(group.emission_receipts)

    wait(2_000, fn ->
      assert %{holders: holders} = receipt_record(receipt)
      assert Map.has_key?(holders, cache)
      assert Map.keys(holders) == [cache]
    end)

    Store.drop_scope(opts.scope)
    wait(2_000, fn -> assert receipt_record(receipt) == nil end)
  end

  test "absolute expiry revokes a held snapshot executor before it can commit" do
    opts = %{options("css-deadline") | attempt_timeout: 100}
    observer = self()

    task =
      Task.async(fn ->
        Execution.run(opts, fn owned ->
          snapshot = stage(owned, "a{background:var(--missing,url(expired.png))}")
          send(observer, {:held_snapshot, self(), snapshot.revision, snapshot.snapshot_receipt})
          receive do: (:never -> :ok)
        end)
      end)

    assert_receive {:held_snapshot, executor, _revision, receipt}, 2_000
    assert Task.await(task, 2_000) == {:error, {:deadline, :attempt}}
    refute Process.alive?(executor)
    wait(2_000, fn -> assert receipt_record(receipt) == nil end)
    assert Process.alive?(Process.whereis(Store))
    assert Process.alive?(Process.whereis(CssSheets))
  end

  defp options(label) do
    scope = unique_scope(label)
    on_exit(fn -> Store.dispose_scope(scope) end)

    %{
      scope: scope,
      generation: Store.generation(scope),
      queue: nil,
      url: "https://css.test/dir/#{label}.css",
      style_group: {:group, label},
      max_body: 262_144,
      max_analysis_bytes: 2_000_000,
      max_css_work: 1_000,
      attempt_timeout: 5_000,
      respect_robots: false
    }
  end

  defp prepared(opts, body) do
    revision = :crypto.hash(:sha256, body)
    id = {revision, :root, opts.url}

    sheet =
      Variables.sheet(Scanner.analyze(body), id, opts.url, 0)
      |> Map.merge(%{region_id: :root, source_revision: revision, imports: []})

    prepared = %{
      style_group: opts.style_group,
      source_revision: revision,
      sheets: [sheet],
      failed: [],
      joined: [opts.url]
    }

    {:ok, bytes} = Retained.bytes(prepared, opts.max_analysis_bytes)
    Map.put(prepared, :bytes, bytes + 16_384)
  end

  defp stage(opts, body) do
    prepared = prepared(opts, body)
    cache = Process.whereis(CssSheets)

    {:ok, descriptor} =
      GenServer.call(cache, {:describe, opts, {opts.scope, opts.generation, opts.style_group}})

    {:ok, facts} = Store.reserve_resource(opts, :css_facts, prepared.bytes, cache)

    {:ok, snapshot} =
      Store.reserve_resource(opts, :css_snapshot, descriptor.bytes + 2 * prepared.bytes, cache)

    {:ok, output} =
      Store.reserve_resource(
        opts,
        :scratch,
        descriptor.bytes + 2 * prepared.bytes + 128 * opts.max_css_work,
        cache
      )

    :ok = Store.retain_resource(facts, Process.whereis(Store))
    opts = Map.put(opts, :css_obligation_receipt, facts)

    {:ok, ref} =
      Store.deliver_resource(
        facts,
        cache,
        {:register, opts,
         Map.put(prepared, :capacities, %{
           snapshot: descriptor.bytes + 2 * prepared.bytes,
           output: descriptor.bytes + 2 * prepared.bytes + 128 * opts.max_css_work
         }), snapshot, output, :resolve}
      )

    receive do
      {:crawler_resource_delivery, ^snapshot, _lease, _origin, ^ref, {:snapshot, payload}} ->
        Map.put(payload, :snapshot_receipt, snapshot)

      {^ref, error} ->
        flunk("snapshot rejected: #{inspect(error)}")
    after
      2_000 -> flunk("snapshot was not delivered")
    end
  end

  defp finish(snapshot, opts) do
    sheets = snapshot.group.sheets |> Map.values() |> Enum.sort_by(& &1.order)
    outcome = Variables.analyze(sheets, true, graph_revision: snapshot.revision)

    urls =
      Enum.map(outcome.pictures, fn picture ->
        {:ok, url} = Crawler.URL.resolve(picture.token.value, picture.base_url)
        url
      end)
      |> Enum.uniq()

    result = %{outcome: outcome, urls: urls, emit?: true}

    with {:ok, bytes} <- Retained.bytes(result, snapshot.output_capacity),
         :ok <- Store.commit_resource(snapshot.output_receipt, bytes),
         {:ok, ref} <-
           Store.deliver_resource(
             snapshot.output_receipt,
             snapshot.cache,
             {:commit, opts, {opts.scope, opts.generation, opts.style_group}, snapshot.revision,
              Map.put(result, :bytes, bytes)}
           ) do
      receive do
        {^ref, :ok} ->
          Store.complete_css(
            opts.execution_lease,
            opts.style_group,
            snapshot.revision,
            {:ok, snapshot.revision}
          )

        {^ref, error} ->
          error
      after
        2_000 -> flunk("commit was not acknowledged")
      end
    end
  end

  defp receipt_record(receipt), do: :sys.get_state(Store).resources.receipts[receipt]
end
