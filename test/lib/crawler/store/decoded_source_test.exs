defmodule Crawler.Store.DecodedSourceTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.Analysis.Limits
  alias Crawler.Charset
  alias Crawler.Fetcher.HeaderPreparer
  alias Crawler.Store.DecodedSource, as: Source
  alias Crawler.Store.Retained

  test "new quotes before retaining complete context and requires exact metadata/workspace" do
    context = context()
    caps = %{pending: 1, context_bytes: 16_384}
    source = make_ref()
    {:ok, bytes} = Retained.bytes(context, caps.context_bytes)
    assert {:ok, need} = Source.requirements_new(source, context, caps, credit(0, 201_216))
    assert need == %{retained_bytes: 4096 + bytes, workspace_bytes: 201_216}

    assert {:error, :unfunded_workspace} =
             Source.new(source, context, caps, credit(need.retained_bytes, 201_215))

    assert {:error, :unfunded_metadata} =
             Source.new(source, context, caps, credit(need.retained_bytes - 1, 201_216))

    assert {:ok, root} = Source.new(source, context, caps, need)
    assert root.metadata_bytes == need.retained_bytes
    assert :erts_debug.same(root.decode_context, context)
    assert root.status == :vacant
    assert Source.cleanup_workspace(root) == 10_752
  end

  test "pending cap one allows one waiter beside its fixed prepaid producer" do
    root = root(1)
    initial = root.metadata_bytes
    producer = acquire(root)
    {{:decode, token}, decoding, [], %{metadata_delta: 0}} = run(root, producer)
    assert decoding.metadata_bytes == initial
    waiting_command = acquire(root)
    {{:waiting, attempt}, full, [], %{metadata_delta: 1024}} = run(decoding, waiting_command)
    assert attempt == elem(waiting_command, 4)
    assert :gb_trees.size(full.waiters) == 1
    assert full.producer == token
    assert full.metadata_bytes == initial + 1024
    refused(full, acquire(root), {:limit, :decoded_source_waiters})
  end

  test "exact producer and waiter acquire duplicates are idempotent and lease conflicts fail" do
    root = root()
    producer = acquire(root)
    {{:decode, token}, decoding, [], _} = run(root, producer)
    {{:decode, ^token}, same, [], %{visited: 0}} = run(decoding, producer, bounds(0, 0))
    assert :erts_debug.same(same, decoding)
    refused(decoding, put_elem(producer, 2, make_ref()), :conflicting_lease)
    refused(decoding, put_elem(producer, 4, make_ref()), :conflicting_lease)
    waiter = acquire(root)
    {{:waiting, attempt}, waiting, [], _} = run(decoding, waiter)
    {{:waiting, ^attempt}, same, [], %{visited: 0}} = run(waiting, waiter, bounds(0, 0))
    assert :erts_debug.same(same, waiting)
    refused(waiting, put_elem(waiter, 2, make_ref()), :conflicting_lease)
    refused(waiting, put_elem(waiter, 4, make_ref()), :conflicting_lease)
  end

  test "pure acquisition linearizations produce one decoder and preserve all other attempts" do
    for order <- [[0, 1, 2, 3], [3, 2, 1, 0], [1, 3, 0, 2]] do
      root = root(3)
      commands = for _ <- 1..4, do: acquire(root)

      {root, results} =
        Enum.reduce(order, {root, []}, fn i, {root, results} ->
          {result, next, [], _} = run(root, Enum.at(commands, i))
          {next, [result | results]}
        end)

      assert Enum.count(results, &match?({:decode, _}, &1)) == 1
      assert Enum.count(results, &match?({:waiting, _}, &1)) == 3
      assert :gb_trees.size(root.waiters) == 3
    end
  end

  test "real UTF16 SVG decoded capsule retains exact checkpoint eleven limits and ownership" do
    Code.ensure_loaded!(Crawler.Analysis)

    for arity <- [2, 3],
        do: :erlang.trace_pattern({Crawler.Analysis, :analyze, arity}, true, [:call_count])

    try do
      root = root()
      {capsule, initial, raw} = capsule(root)
      assert capsule.body != raw
      assert String.valid?(capsule.body)
      assert capsule.body =~ "utf-8"
      assert capsule.body =~ "svg:svg"
      assert capsule.root_ownership == :retained
      assert capsule.decoder_seed.retained >= initial.retained
      assert capsule.decoder_seed.counts == initial.counts
      assert capsule.decoder_seed.caps == initial.caps
      assert capsule.decoder_seed.peak >= capsule.decoder_seed.retained
      assert capsule.decoder_seed.scratch == 0
      assert capsule.unavailable == initial.retained
      assert map_size(capsule.limits) == 11
      assert {:ok, full_copy_bytes} = Retained.copy_bytes(capsule, 10_000_000)
      assert full_copy_bytes > byte_size(capsule.body)
      {{:decode, token}, root, [], _} = run(root, acquire(root))
      {:ok, ready, [], %{metadata_delta: 0}} = run(root, {:publish, token, capsule})
      {{:decoded, borrowed}, same, [], %{visited: 0}} = run(ready, acquire(ready), bounds(0, 0))
      assert :erts_debug.same(same, ready)
      assert :erts_debug.same(borrowed, capsule)
      assert :erts_debug.same(borrowed.body, capsule.body)
      assert :erts_debug.same(borrowed.decoder_seed, capsule.decoder_seed)
      assert :erts_debug.same(borrowed.limits, capsule.limits)
      refute Map.has_key?(ready, :analysis)
      refute Map.has_key?(ready, :response)
      refute Map.has_key?(ready, :url)

      for arity <- [2, 3],
          do:
            assert(
              {:call_count, 0} ==
                :erlang.trace_info({Crawler.Analysis, :analyze, arity}, :call_count)
            )
    after
      for arity <- [2, 3],
          do: :erlang.trace_pattern({Crawler.Analysis, :analyze, arity}, false, [:call_count])
    end
  end

  test "empty or unchanged actual decode preserves borrowed ownership without manufacturing a new seed" do
    root = root()
    {:ok, limits} = Limits.new(%{})
    {:ok, seed} = Budget.charge(Budget.new(limits), 1234, facts: 2)
    {:ok, body, same_seed, ownership} = Charset.decode_owned_result("", root.decode_context, seed)
    assert body == ""
    assert ownership == :borrowed
    assert :erts_debug.same(same_seed, seed)
    {entry, _, _} = capsule(root)

    entry = %{
      entry
      | body: body,
        decoder_seed: same_seed,
        limits: limits,
        unavailable: seed.retained,
        root_ownership: ownership
    }

    {{:decode, token}, root, [], _} = run(root, acquire(root))
    {:ok, ready, [], _} = run(root, {:publish, token, entry})
    assert :erts_debug.same(ready.capsule.decoder_seed, seed)
    assert ready.capsule.root_ownership == :borrowed
  end

  test "publication is once-only CAS and rejects foreign physical source context and tokens" do
    root = root()
    {capsule, _, _} = capsule(root)
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    refused(root, {:publish, put_elem(token, 0, make_ref()), capsule}, :stale_producer)
    refused(root, {:publish, put_elem(token, 1, make_ref()), capsule}, :stale_producer)
    refused(root, {:publish, put_elem(token, 3, make_ref()), capsule}, :stale_producer)
    refused(root, {:publish, token, %{capsule | source_revision: make_ref()}}, :stale_source)

    refused(
      root,
      {:publish, token, %{capsule | decode_context: context([{"x", "different"}])}},
      :incompatible_decode_context
    )

    {:ok, ready, [], _} = run(root, {:publish, token, capsule})
    refused(ready, {:publish, token, capsule}, :already_published)
    refused(ready, {:publish, token, %{capsule | copy_receipt: make_ref()}}, :already_published)
    assert :erts_debug.same(ready.capsule, capsule)
  end

  test "published owner departure keeps host-owned root and rejects changed canonical target while recorded" do
    root = root()
    producer = acquire(root)
    {{:decode, token}, root, [], _} = run(root, producer)
    {capsule, _, _} = capsule(root)
    {:ok, ready, [], _} = run(root, {:publish, token, capsule})
    refused(ready, put_elem(producer, 2, make_ref()), :conflicting_lease)
    {:ok, next, [], _} = run(ready, {:owner_down, elem(token, 2)})
    assert next.status == :ready
    assert next.published_token == nil
    assert :erts_debug.same(next.capsule, capsule)
    assert next.releases == []
  end

  test "owner death invalidates producer immediately then wakes FIFO retries one per drain" do
    root = root(2)
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    first = acquire(root)
    second = acquire(root)
    {{:waiting, _}, root, [], _} = run(root, first)
    {{:waiting, _}, root, [], _} = run(root, second)
    {incoming, _, _} = capsule(root)
    {:ok, vacant, [], %{visited: 1, metadata_delta: 0}} = run(root, {:owner_down, elem(token, 2)})
    assert vacant.status == :vacant
    assert vacant.producer == nil
    refused(vacant, {:publish, token, incoming}, :stale_producer)
    refused(vacant, acquire(vacant), :source_busy)
    {{:more, 1}, next, [wake1], _} = run(vacant, :drain)
    assert wake1 == wake(vacant, first, :retry)
    {{:done, 1}, empty, [wake2], _} = run(next, :drain)
    assert wake2 == wake(vacant, second, :retry)
    assert :gb_trees.is_empty(empty.waiters)
    assert empty.head == nil and empty.tail == nil and empty.wake_reason == nil
    {{:decode, new_token}, decoding, [], _} = run(empty, acquire(empty))
    refute new_token == token
    refused(decoding, {:publish, token, incoming}, :stale_producer)
  end

  test "indexed middle head and tail waiter removal preserves remaining FIFO wakes" do
    root = root(4)
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    commands = for _ <- 1..4, do: acquire(root)

    root =
      Enum.reduce(commands, root, fn command, root ->
        {{:waiting, _}, root, [], _} = run(root, command)
        root
      end)

    for removed <- [[1], [0], [3], [1, 0, 3]] do
      next =
        Enum.reduce(removed, root, fn i, root ->
          {:ok, next, [], %{visited: 1, metadata_delta: -1024}} =
            run(root, {:owner_down, elem(Enum.at(commands, i), 3)})

          next
        end)

      {capsule, _, _} = capsule(next)
      {:ok, next, [], _} = run(next, {:publish, token, capsule})
      {empty, effects} = drain(next)

      expected =
        commands
        |> Enum.with_index()
        |> Enum.reject(fn {_, i} -> i in removed end)
        |> Enum.map(fn {cmd, _} -> wake(next, cmd, :ready) end)

      assert effects == expected
      assert :gb_trees.is_empty(empty.waiters)
      assert empty.head == nil and empty.tail == nil
    end
  end

  test "retirement while computing fences publication before bounded retired wakes" do
    root = root(1)
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    waiter = acquire(root)
    {{:waiting, _}, root, [], _} = run(root, waiter)
    {incoming, _, _} = capsule(root)
    {:ok, retiring, [], %{visited: 0}} = run(root, :retire, bounds(0, 0))
    assert retiring.status == :retiring
    assert retiring.producer == nil
    refused(retiring, {:publish, token, incoming}, :stale_source)
    refused(retiring, acquire(root), :stale_source)
    {{:done, 1}, empty, [effect], _} = run(retiring, :drain)
    assert effect == wake(root, waiter, :retired)
    assert empty.releases == []
    {{:done, 0}, same, [], _} = run(empty, :drain, bounds(0, 0))
    assert :erts_debug.same(same, empty)
  end

  test "ready retirement clears payload then releases all nine unique receipts exactly once" do
    root = root()
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    waiter = acquire(root)
    {{:waiting, _}, root, [], _} = run(root, waiter)
    {entry, _, _} = capsule(root)

    entry = %{
      entry
      | retained_receipts: for(_ <- 1..4, do: make_ref()),
        backing_receipts: for(_ <- 1..4, do: make_ref())
    }

    {:ok, ready, [], _} = run(root, {:publish, token, entry})
    {:ok, retiring, [], %{metadata_delta: 0}} = run(ready, :retire, bounds(0, 0))
    assert retiring.capsule == nil
    assert length(retiring.releases) == 9
    {:ok, same, [], _} = run(retiring, :retire, bounds(0, 0))
    assert :erts_debug.same(same, retiring)
    {empty, effects} = drain(retiring)
    assert hd(effects) == wake(root, waiter, :retired)
    assert tl(effects) == Enum.map(receipts(entry), &{:release, &1})
    assert length(effects) == 10
    assert empty.metadata_bytes == root.metadata_bytes - 1024
    assert empty.releases == []
    {same, []} = drain(empty)
    assert :erts_debug.same(same, empty)
  end

  test "overlapping receipt references receive one release without an authority oracle" do
    root = root()
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    {entry, _, _} = capsule(root)
    shared = make_ref()

    entry = %{
      entry
      | copy_receipt: shared,
        retained_receipts: [shared, shared],
        backing_receipts: [shared]
    }

    {:ok, ready, [], _} = run(root, {:publish, token, entry})
    {:ok, retiring, [], _} = run(ready, :retire)
    {_empty, effects} = drain(retiring)
    assert effects == [{:release, shared}]
  end

  test "zero visit/effect bounds refuse drains without changing state or refunding metadata" do
    root = root(1)
    refused(root, acquire(root), :visit_capacity, bounds(0, 0))
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    {{:waiting, _}, root, [], _} = run(root, acquire(root))
    {{:done, 0}, same, [], _} = run(root, :drain, bounds(0, 0))
    assert :erts_debug.same(same, root)
    {entry, _, _} = capsule(root)
    refused(root, {:publish, token, entry}, :visit_capacity, bounds(0, 0))
    {:ok, ready, [], _} = run(root, {:publish, token, entry})
    refused(ready, :drain, :visit_capacity, bounds(0, 1))
    refused(ready, :drain, :effect_capacity, bounds(1, 0))
    {:ok, retiring, [], _} = run(ready, :retire)
    {_empty, effects} = drain(retiring)
    assert length(effects) == 4
  end

  test "exact quoted metadata/workspace suffices and one byte less rejects before growth" do
    root = root(1)
    {{:decode, _}, root, [], _} = run(root, acquire(root))
    command = acquire(root)
    {:ok, quote} = requirements(root, command)
    assert quote.retained_bytes == 1024
    assert quote.workspace_bytes == 201_216
    refused_credit(root, command, credit(1023, quote.workspace_bytes), :unfunded_metadata)
    refused_credit(root, command, credit(1024, quote.workspace_bytes - 1), :unfunded_workspace)

    {{:waiting, _}, full, [], _} =
      Source.transition(
        root,
        command,
        bounds(),
        credit(quote.retained_bytes, quote.workspace_bytes)
      )

    {:ok, retiring, [], _} = run(full, :retire)

    {{:done, 1}, empty, [_], %{metadata_delta: -1024}} =
      Source.transition(retiring, :drain, bounds(), credit(0, Source.cleanup_workspace(retiring)))

    assert empty.metadata_bytes == full.metadata_bytes - 1024
  end

  test "large configured cap does not reserve future waiter nodes for an empty source" do
    root = root(100_000)
    assert Source.cleanup_workspace(root) == 43_520
    {:ok, acquire} = requirements(root, acquire(root))
    assert acquire.retained_bytes == 0
    assert acquire.workspace_bytes == 201_216
    {:ok, retire} = requirements(root, :retire)
    assert retire.retained_bytes == 0
    assert retire.workspace_bytes == 4096
    assert retire.context_walk_steps_upper == 0
    assert root.metadata_bytes < 16_384
  end

  test "insertion rebalance quote uses current nodes while cleanup stays small at capacity" do
    root = root(1024)
    {{:decode, _}, root, [], _} = run(root, acquire(root))

    root =
      Enum.reduce(1..1023, root, fn _, root ->
        {{:waiting, _}, next, [], _} = run(root, acquire(root))
        next
      end)

    command = acquire(root)
    {:ok, quote} = requirements(root, command)
    assert quote.workspace_bytes > 201_216

    refused_credit(
      root,
      command,
      credit(quote.retained_bytes, quote.workspace_bytes - 1),
      :unfunded_workspace
    )

    {{:waiting, _}, full, [], _} =
      Source.transition(
        root,
        command,
        bounds(),
        credit(quote.retained_bytes, quote.workspace_bytes)
      )

    assert :gb_trees.size(full.waiters) == 1024
    {:ok, retiring, [], _} = run(full, :retire)

    {_, next, [_], %{visited: 1, metadata_delta: -1024}} =
      Source.transition(retiring, :drain, bounds(), credit(0, Source.cleanup_workspace(retiring)))

    assert :gb_trees.size(next.waiters) == 1023
    assert Source.cleanup_workspace(retiring) < 43_520
  end

  test "exact canonical atom charlist and numeric headers are retained without extra header storage" do
    for headers <- [
          [{:link, "<a>; rel=stylesheet"}],
          [{~c"link", "<b>"}],
          [{1, "ignored"}],
          [{1.0, "ignored"}]
        ] do
      context = context(headers)
      root = root(1, context)
      {entry, _, _} = capsule(root)
      {{:decode, token}, root, [], _} = run(root, acquire(root))
      {:ok, ready, [], _} = run(root, {:publish, token, entry})
      {{:decoded, candidate}, same, [], _} = run(ready, acquire(ready))
      assert :erts_debug.same(same, ready)
      assert :erts_debug.same(candidate.decode_context.headers, headers)
      assert :erts_debug.same(candidate.decode_context, context)
      refute Map.has_key?(candidate, :headers)
      refute Map.has_key?(ready, :headers)
    end
  end

  test "numeric ordering aliases are incompatible before any native lease comparison" do
    context = context([{1, "ignored"}])
    root = root(1, context)
    command = acquire(root)
    {{:decode, token}, root, [], _} = run(root, command)
    alias_context = context([{1.0, "ignored"}])
    assert alias_context == context
    refute alias_context === context
    {entry, _, _} = capsule(root)

    trace_zero_lookups(fn ->
      refused(
        root,
        {:acquire, alias_context, make_ref(), make_ref(), make_ref()},
        :incompatible_decode_context
      )

      refused(
        root,
        {:publish, token, %{entry | decode_context: alias_context}},
        :incompatible_decode_context
      )
    end)
  end

  test "long equal prefixes exceed complete context backing cap before native lookup" do
    headers = List.duplicate({"x", "prefix"}, 50)
    root = root(2, context(headers))
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    {{:waiting, _}, root, [], _} = run(root, acquire(root))
    {entry, _, _} = capsule(root)
    {:ok, ready, [], _} = run(root, {:publish, token, entry})

    oversized = %{
      root.decode_context
      | headers: headers ++ [{"x", String.duplicate("x", 32_768)}]
    }

    trace_zero_lookups(fn ->
      refused(
        ready,
        {:acquire, oversized, make_ref(), make_ref(), make_ref()},
        {:limit, :max_retained_bytes}
      )

      refused(
        root,
        {:publish, token, %{entry | decode_context: oversized}},
        {:limit, :max_retained_bytes}
      )
    end)
  end

  test "unfunded malformed or function contexts do no native lookup and cannot grow state" do
    root = root()
    {{:decode, _}, root, [], _} = run(root, acquire(root))

    invalid = [
      nil,
      %{content_type: :invalid, headers: []},
      %{content_type: nil, headers: :invalid},
      %{content_type: nil, headers: [], extra: nil},
      %{content_type: nil, headers: [{1, "x"} | :bad]}
    ]

    trace_zero_lookups(fn ->
      for context <- invalid do
        refused(
          root,
          {:acquire, context, make_ref(), make_ref(), make_ref()},
          :invalid_decode_context
        )
      end

      refused(
        root,
        {:acquire, %{content_type: nil, headers: [{1, fn -> :ignored end}]}, make_ref(),
         make_ref(), make_ref()},
        {:limit, :decoded_source_context_term}
      )

      refused_credit(root, acquire(root), credit(0, 98_304), :unfunded_workspace)
    end)
  end

  test "funding check precedes real Retained calls and function environments are not materialized" do
    root = root()
    :erlang.trace_pattern({Retained, :bytes, 2}, true, [:call_count])

    try do
      refused_credit(root, acquire(root), credit(0, 201_215), :unfunded_workspace)
      context = %{root.decode_context | headers: [{1, fn -> root end}]}

      refused(
        root,
        {:acquire, context, make_ref(), make_ref(), make_ref()},
        {:limit, :decoded_source_context_term}
      )

      assert {:call_count, 0} = :erlang.trace_info({Retained, :bytes, 2}, :call_count)
    after
      :erlang.trace_pattern({Retained, :bytes, 2}, false, [:call_count])
    end
  end

  test "receipt-only drain needs one visit and effect while retaining no capsule" do
    root = root()
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    {entry, _, _} = capsule(root)
    {:ok, ready, [], _} = run(root, {:publish, token, entry})
    {:ok, retiring, [], _} = run(ready, :retire, bounds(0, 0))
    assert retiring.capsule == nil
    refused(retiring, :drain, :visit_capacity, bounds(0, 1))
    refused(retiring, :drain, :effect_capacity, bounds(1, 0))

    {{:more, 1}, next, [{:release, receipt}], %{visited: 1, effects: 1, metadata_delta: 0}} =
      Source.transition(retiring, :drain, bounds(), credit(0, Source.cleanup_workspace(retiring)))

    assert receipt == entry.copy_receipt
    assert next.capsule == nil
    assert length(next.releases) == 2
  end

  test "nil header container stays exact and cannot alias an empty canonical list" do
    exact = context(nil)
    root = root(1, exact)
    assert root.decode_context.headers == nil
    {{:decode, token}, decoding, [], _} = run(root, acquire(root))

    refused(
      decoding,
      {:acquire, context([]), make_ref(), make_ref(), make_ref()},
      :incompatible_decode_context
    )

    :erlang.trace_pattern({:gb_trees, :lookup, 2}, true, [:call_count])

    try do
      {:ok, vacant, [], %{metadata_delta: 0}} = run(decoding, {:owner_down, elem(token, 2)})
      assert vacant.status == :vacant
      assert vacant.wake_reason == nil
      assert :erts_debug.same(vacant.waiters, decoding.waiters)
      assert {:call_count, 0} = :erlang.trace_info({:gb_trees, :lookup, 2}, :call_count)
    after
      :erlang.trace_pattern({:gb_trees, :lookup, 2}, false, [:call_count])
    end
  end

  test "bounded structural preflight stops depth map-space and work overflow before lookup" do
    root = root()
    {{:decode, _}, root, [], _} = run(root, acquire(root))
    too_deep = Enum.reduce(1..257, nil, fn _, nested -> {nested} end)
    too_wide = Map.new(1..512, &{&1, &1})
    too_long = List.duplicate({1, "ignored"}, 25_001)

    trace_zero_lookups(fn ->
      for headers <- [[{1, too_deep}], [{1, too_wide}], too_long] do
        supplied = %{root.decode_context | headers: headers}

        refused(
          root,
          {:acquire, supplied, make_ref(), make_ref(), make_ref()},
          {:limit, :max_retained_bytes}
        )
      end
    end)
  end

  test "function resource limit refuses fresh and existing contexts at exact workspace with no custody change" do
    root = root()
    {{:decode, token}, decoding, [], _} = run(root, acquire(root))
    {entry, _, _} = capsule(decoding)
    function = fn -> root end
    supplied = %{root.decode_context | headers: [{1, %{nested: [function]}}]}
    :erlang.trace_pattern({Retained, :bytes, 2}, true, [:call_count])

    try do
      trace_zero_lookups(fn ->
        caps = %{pending: 1, context_bytes: 16_384}

        assert {:error, {:limit, :decoded_source_context_term}} =
                 Source.requirements_new(make_ref(), supplied, caps, credit(0, 201_216))

        assert {:error, {:limit, :decoded_source_context_term}} =
                 Source.new(make_ref(), supplied, caps, credit(0, 201_216))

        for command <- [
              {:acquire, supplied, make_ref(), make_ref(), make_ref()},
              {:publish, token, %{entry | decode_context: supplied}}
            ] do
          refused_credit(
            decoding,
            command,
            credit(0, 201_216),
            {:limit, :decoded_source_context_term}
          )
        end
      end)

      assert {:call_count, 0} = :erlang.trace_info({Retained, :bytes, 2}, :call_count)
    after
      :erlang.trace_pattern({Retained, :bytes, 2}, false, [:call_count])
    end

    assert decoding.capsule == nil
  end

  test "canonical supported nested header terms remain exact without member semantics" do
    nested = %{
      atom: :yes,
      binary: "payload",
      values: [~c"characters", 1, 1.0, {:nested, make_ref()}]
    }

    headers = [{1, nested}]
    context = context(headers)
    root = root(1, context)
    {entry, _, _} = capsule(root)
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    {:ok, ready, [], _} = run(root, {:publish, token, entry})
    {{:decoded, candidate}, same, [], _} = run(ready, acquire(ready))
    assert :erts_debug.same(same, ready)
    assert :erts_debug.same(candidate.decode_context, context)
    assert :erts_debug.same(candidate.decode_context.headers, headers)
    assert :erts_debug.same(hd(candidate.decode_context.headers) |> elem(1), nested)
  end

  test "caps bounds malformed capsules and source separation fail without granting custody" do
    for caps <- [
          %{pending: 0, context_bytes: 1000},
          %{pending: 1, context_bytes: 0},
          %{pending: 134_217_728, context_bytes: 1},
          %{pending: 1, context_bytes: 1, extra: 0}
        ] do
      assert {:error, :invalid_caps} = Source.new(make_ref(), context(), caps, credit(0, 201_216))
    end

    assert {:error, :invalid_source_revision} =
             Source.new(nil, context(), %{pending: 1, context_bytes: 1000}, credit(0, 201_216))

    assert {:error, {:limit, :max_retained_bytes}} =
             Source.new(
               make_ref(),
               context(),
               %{pending: 1, context_bytes: 1},
               credit(0, 201_216)
             )

    root = root()
    {{:decode, token}, root, [], _} = run(root, acquire(root))
    {entry, _, _} = capsule(root)

    for invalid <- [
          Map.put(entry, :analysis, nil),
          %{
            entry
            | retained_receipts: [make_ref(), make_ref(), make_ref(), make_ref(), make_ref()]
          },
          %{entry | backing_receipts: [:bad]},
          %{entry | limits: %{}},
          %{entry | decoder_seed: nil},
          %{entry | root_ownership: :invented},
          %{entry | body: []}
        ] do
      refused(root, {:publish, token, invalid}, :invalid_capsule)
    end

    refused(root, :drain, :invalid_bounds, %{max_visits: 2, max_effects: 1})

    refused_credit(
      root,
      :drain,
      %{retained_bytes: 0, workspace_bytes: 4096, extra: 0},
      :invalid_prepaid
    )

    foreign = root(1, root.decode_context)
    refused(foreign, {:publish, token, entry}, :stale_producer)
  end

  test "standalone context measurement quotes full exact supported terms with no root construction" do
    headers = [
      {"Content-Type", "image/svg+xml"},
      {:link, ~c"stylesheet"},
      {1, %{nested: [:atom, "binary", ~c"chars", 1, 1.0, {make_ref(), nil}]}},
      {1.0, "ignored"}
    ]

    supplied = context(headers)
    prepaid = credit(0, Source.context_workspace())
    assert Source.context_workspace() == 201_216
    {:ok, complete} = Retained.bytes(supplied, 16_384)
    {:ok, headers_only} = Retained.bytes(headers, 16_384)
    assert complete > headers_only
    :erlang.trace_pattern({Source, :new, 4}, true, [:call_count])

    try do
      trace_zero_lookups(fn ->
        assert {:ok, ^complete} = Source.context_bytes(supplied, complete, prepaid)
        assert {:ok, ^complete} = Source.context_bytes(supplied, 134_217_727, prepaid)

        assert {:error, {:limit, :max_retained_bytes}} =
                 Source.context_bytes(supplied, complete - 1, prepaid)
      end)

      assert {:call_count, 0} = :erlang.trace_info({Source, :new, 4}, :call_count)
    after
      :erlang.trace_pattern({Source, :new, 4}, false, [:call_count])
    end

    assert :erts_debug.same(supplied.headers, headers)
  end

  test "standalone context measurement checks workspace before context limit or Retained work" do
    malformed = %{content_type: :invalid, headers: :invalid}
    :erlang.trace_pattern({Retained, :bytes, 2}, true, [:call_count])

    try do
      trace_zero_lookups(fn ->
        for limit <- [nil, 0, -1, 1.0, 134_217_728] do
          assert {:error, :unfunded_workspace} =
                   Source.context_bytes(malformed, limit, credit(0, 201_215))

          assert {:error, :invalid_context_limit} =
                   Source.context_bytes(malformed, limit, credit(0, 201_216))
        end

        assert {:error, :invalid_prepaid} =
                 Source.context_bytes(malformed, 0, %{workspace_bytes: 201_216})

        assert {:error, :invalid_decode_context} =
                 Source.context_bytes(malformed, 1, credit(0, 201_216))

        assert {:error, :invalid_decode_context} =
                 Source.context_bytes(nil, 1, credit(0, 201_216))
      end)

      assert {:call_count, 0} = :erlang.trace_info({Retained, :bytes, 2}, :call_count)
    after
      :erlang.trace_pattern({Retained, :bytes, 2}, false, [:call_count])
    end
  end

  test "standalone function resource limit precedes byte overflow with exact workspace and zero Retained calls" do
    captured = ["private", make_ref()]
    function = fn -> captured end
    supplied = context([{1, %{nested: [function]}}])
    :erlang.trace_pattern({Retained, :bytes, 2}, true, [:call_count])

    try do
      trace_zero_lookups(fn ->
        assert {:error, :unfunded_workspace} =
                 Source.context_bytes(supplied, 1, credit(0, 201_215))

        assert {:error, :invalid_context_limit} =
                 Source.context_bytes(supplied, 0, credit(0, 201_216))

        for limit <- [1, 16_384, 134_217_727] do
          assert {:error, {:limit, :decoded_source_context_term}} =
                   Source.context_bytes(supplied, limit, credit(0, 201_216))
        end
      end)

      assert {:call_count, 0} = :erlang.trace_info({Retained, :bytes, 2}, :call_count)
    after
      :erlang.trace_pattern({Retained, :bytes, 2}, false, [:call_count])
    end
  end

  test "constructor requirements and acquire compatibility reuse the public measurement boundary" do
    source = make_ref()
    supplied = context()
    caps = %{pending: 1, context_bytes: 16_384}
    prepaid = credit(0, Source.context_workspace())
    :erlang.trace_pattern({Source, :context_bytes, 3}, true, [:call_count])

    try do
      {:ok, creation} = Source.requirements_new(source, supplied, caps, prepaid)
      assert {:call_count, 1} = :erlang.trace_info({Source, :context_bytes, 3}, :call_count)
      {:ok, root} = Source.new(source, supplied, caps, creation)
      assert {:call_count, 2} = :erlang.trace_info({Source, :context_bytes, 3}, :call_count)
      command = acquire(root)
      {:ok, need} = Source.requirements(root, command, bounds(), prepaid)
      assert {:call_count, 3} = :erlang.trace_info({Source, :context_bytes, 3}, :call_count)

      {{:decode, _}, decoding, [], _} =
        Source.transition(
          root,
          command,
          bounds(),
          credit(need.retained_bytes, need.workspace_bytes)
        )

      assert {:call_count, 4} = :erlang.trace_info({Source, :context_bytes, 3}, :call_count)
      assert decoding.decode_context === supplied
    after
      :erlang.trace_pattern({Source, :context_bytes, 3}, false, [:call_count])
    end
  end

  defp context(headers \\ [{"Content-Type", "image/svg+xml; charset=utf-16"}]) do
    prepared = HeaderPreparer.prepare(headers, %{})
    Map.take(prepared, [:content_type, :headers])
  end

  defp root(cap \\ 4, context \\ context()) do
    caps = %{pending: cap, context_bytes: 16_384}
    {:ok, quote} = Source.requirements_new(make_ref(), context, caps, credit(0, 201_216))
    {:ok, root} = Source.new(make_ref(), context, caps, quote)
    root
  end

  defp capsule(root) do
    {:ok, limits} = Limits.new(%{max_total_bytes: 2_000_000, max_bytes: 1_000_000})
    {:ok, initial} = Budget.charge(Budget.new(limits), 17_000, facts: 2, regions: 1)

    raw =
      <<0xFF, 0xFE>> <>
        :unicode.characters_to_binary(
          ~s(<?xml version="1.0" encoding="utf-16"?><svg:svg xmlns:svg="http://www.w3.org/2000/svg"/>),
          :utf8,
          {:utf16, :little}
        )

    opts = Map.put(root.decode_context, :max_body, limits.max_bytes)
    {:ok, body, seed, ownership} = Charset.decode_owned_result(raw, opts, initial)

    {%{
       source_revision: root.source_revision,
       decode_context: root.decode_context,
       body: body,
       decoder_seed: seed,
       limits: limits,
       unavailable: initial.retained,
       root_ownership: ownership,
       retained_receipts: [make_ref()],
       backing_receipts: [make_ref()],
       copy_receipt: make_ref()
     }, initial, raw}
  end

  defp bounds(v \\ 1, e \\ 1), do: %{max_visits: v, max_effects: e}
  defp credit(r, w), do: %{retained_bytes: r, workspace_bytes: w}
  defp acquire(root), do: {:acquire, root.decode_context, make_ref(), make_ref(), make_ref()}

  defp requirements(root, command, limits \\ bounds()),
    do:
      Source.requirements(
        root,
        command,
        limits,
        credit(0, max(201_216, Source.cleanup_workspace(root)))
      )

  defp run(root, command, limits \\ bounds()) do
    case requirements(root, command, limits) do
      {:ok, need} ->
        Source.transition(
          root,
          command,
          limits,
          credit(need.retained_bytes, need.workspace_bytes)
        )

      {:error, _} ->
        Source.transition(
          root,
          command,
          limits,
          credit(0, max(201_216, Source.cleanup_workspace(root)))
        )
    end
  end

  defp refused(root, command, reason, limits \\ bounds()) do
    assert {:error, ^reason} = requirements(root, command, limits)

    assert {{:error, ^reason}, same, [], %{visited: 0, effects: 0, metadata_delta: 0}} =
             run(root, command, limits)

    assert :erts_debug.same(same, root)
  end

  defp refused_credit(root, command, prepaid, reason) do
    assert {{:error, ^reason}, same, [], %{visited: 0, effects: 0, metadata_delta: 0}} =
             Source.transition(root, command, bounds(), prepaid)

    assert :erts_debug.same(same, root)
  end

  defp wake(root, command, reason),
    do: {:wake, root.source_revision, elem(command, 2), elem(command, 3), reason}

  defp receipts(entry),
    do: Enum.uniq([entry.copy_receipt | entry.retained_receipts ++ entry.backing_receipts])

  defp drain(root, effects \\ []) do
    case run(root, :drain) do
      {{:done, _}, next, last, _} -> {next, effects ++ last}
      {{:more, 1}, next, [effect], %{visited: 1, effects: 1}} -> drain(next, effects ++ [effect])
    end
  end

  defp trace_zero_lookups(fun) do
    :erlang.trace_pattern({:gb_trees, :lookup, 2}, true, [:call_count])

    try do
      fun.()
      assert {:call_count, 0} = :erlang.trace_info({:gb_trees, :lookup, 2}, :call_count)
    after
      :erlang.trace_pattern({:gb_trees, :lookup, 2}, false, [:call_count])
    end
  end
end
