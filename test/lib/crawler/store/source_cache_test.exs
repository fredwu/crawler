defmodule Crawler.Store.SourceCacheTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Analysis.Limits
  alias Crawler.Charset
  alias Crawler.Store.Retained
  alias Crawler.Store.SourceCache, as: Cache

  test "caps and call credit are explicit and cannot create metadata authority" do
    caps = %{slots: 2, waiters: 2, key_bytes: 16_384}
    assert {:error, :unfunded_metadata} = Cache.new(make_ref(), caps, credit(4095, 4096))
    assert {:error, :unfunded_workspace} = Cache.new(make_ref(), caps, credit(4096, 4095))
    assert {:error, :invalid_caps} = Cache.new(make_ref(), %{}, credit(4096, 4096))
    assert {:error, :invalid_caps} = Cache.new(make_ref(), %{caps | slots: 0}, credit(4096, 4096))

    assert {:error, :invalid_caps} =
             Cache.new(make_ref(), Map.put(caps, :default, 1), credit(4096, 4096))

    assert {:error, :invalid_caps} =
             Cache.new(make_ref(), %{caps | waiters: 134_217_727}, credit(4096, 4096))
  end

  test "requirements reject before key walking and any persistent growth" do
    cache = cache()
    command = acquire(key())

    assert {:error, :unfunded_workspace} =
             Cache.requirements(cache, command, bounds(), credit(0, 0))

    price = price(cache, command)
    before = cache

    assert {{:error, :unfunded_metadata}, ^cache, [], %{visited: 0, metadata_delta: 0}} =
             Cache.transition(
               cache,
               command,
               bounds(),
               credit(price.retained_bytes - 1, price.workspace_bytes)
             )

    assert :erts_debug.same(cache, before)

    assert {{:error, :unfunded_workspace}, ^cache, [], _} =
             Cache.transition(
               cache,
               command,
               bounds(),
               credit(price.retained_bytes, price.workspace_bytes - 1)
             )

    assert :gb_trees.is_empty(cache.keys)
  end

  test "an empty cache does not reserve its configured future population" do
    small = cache(%{slots: 1, waiters: 0, key_bytes: 16_384})
    large = cache(%{slots: 50_000, waiters: 50_000, key_bytes: 16_384})
    assert price(small, acquire(key())) == price(large, acquire(key()))
    assert price(large, :retire, bounds(0, 0)).workspace_bytes < 5000
    assert price(large, acquire(key())).workspace_bytes < 140_000
    assert Cache.cleanup_workspace(large) < 700_000
  end

  test "lexical slots use physical identity and canonical references, not URL identity" do
    cache = cache()
    command = acquire(key())
    {{:compute, token}, cache, [], %{visited: 1}} = run(cache, command)
    assert elem(token, 0) == cache.source_revision
    assert elem(token, 2) == elem(command, 2)
    assert elem(token, 3) == elem(command, 3)

    assert {:error, :duplicate_attempt} =
             Cache.requirements(cache, command, bounds(), quote_credit())

    assert {:error, :invalid_command} =
             Cache.requirements(
               cache,
               {:acquire, key(), "https://example.test/", make_ref(), make_ref()},
               bounds(),
               quote_credit()
             )

    assert {:error, :invalid_lexical_key} =
             Cache.requirements(
               cache,
               acquire({:unknown, "text/html", []}),
               bounds(),
               quote_credit()
             )
  end

  test "finite slot and waiter caps reject without growing state" do
    cache = cache(%{slots: 1, waiters: 1, key_bytes: 16_384})
    {_, cache, _, _} = run(cache, acquire(key()))
    {_, cache, _, _} = run(cache, acquire(key()))

    assert {:error, {:limit, :source_cache_waiters}} =
             Cache.requirements(cache, acquire(key()), bounds(), quote_credit())

    assert {:error, {:limit, :source_cache_slots}} =
             Cache.requirements(cache, acquire(key("text/css")), bounds(), quote_credit())

    assert :gb_trees.size(cache.slots) == 1
    assert :gb_trees.size(cache.waiters) == 1
  end

  test "publication retains the exact private analysis and bounded receipt capsule" do
    {entry, opts} = entry()
    cache = cache()
    entry = %{entry | source_revision: cache.source_revision}
    {{:compute, token}, cache, _, _} = run(cache, acquire(entry.lexical_key))
    {{:waiting, _}, cache, _, _} = run(cache, acquire(entry.lexical_key))
    assert {:ok, bytes} = Retained.copy_bytes(entry, 8_000_000)
    assert bytes > entry.analysis.allocation.retained
    {:published, cache, [], _} = run(cache, {:publish, token, entry})
    {{:candidate, candidate}, same, [], _} = run(cache, acquire(entry.lexical_key))
    assert :erts_debug.same(candidate, entry)
    assert :erts_debug.same(same, cache)
    assert candidate.analysis.source_options.headers == opts.headers
    assert candidate.analysis.allocation.seed == entry.analysis.allocation.seed
    {{:done, 1}, cache, [{:wake, _, _, :ready}], _} = run(cache, {:drain, 1}, bounds(1, 1))
    assert :gb_trees.is_empty(cache.waiters)
    assert :gb_trees.is_empty(cache.requests)
    assert :gb_trees.is_empty(cache.leases)
  end

  test "duplicate publication does not release a capsule still held by the slot" do
    {entry, _} = entry()
    cache = cache()
    entry = %{entry | source_revision: cache.source_revision}
    {{:compute, token}, cache, _, _} = run(cache, acquire(entry.lexical_key))
    {:published, cache, _, _} = run(cache, {:publish, token, entry})

    assert {{:error, :already_published}, ^cache, [], _} =
             run(cache, {:publish, token, entry})
  end

  test "physical revision and key CAS reject stale transfers with bounded releases" do
    {entry, _} = entry()
    cache = cache()
    {{:compute, token}, cache, _, _} = run(cache, acquire(entry.lexical_key))
    refs = refs(entry)

    assert {{:error, :stale_token}, ^cache, effects, _} =
             run(cache, {:publish, token, entry}, bounds(1, 9))

    assert Enum.sort(effects) == Enum.sort(Enum.map(refs, &{:release, &1}))
    wrong_key = %{entry | source_revision: cache.source_revision}
    other = cache()

    assert {{:error, :stale_token}, ^other, _, _} =
             run(other, {:publish, token, wrong_key}, bounds(1, 9))

    assert {:error, :effect_capacity} =
             Cache.requirements(cache, {:publish, token, entry}, bounds(1, 0), quote_credit())
  end

  test "source retirement invalidates a held producer before bounded cleanup" do
    {entry, _} = entry()
    cache = cache()
    entry = %{entry | source_revision: cache.source_revision}
    {{:compute, token}, cache, _, _} = run(cache, acquire(entry.lexical_key))
    {_, cache, _, _} = run(cache, acquire(entry.lexical_key))
    {{:more, 0}, cache, [], _} = run(cache, :retire, bounds(0, 0))
    assert cache.status == :retiring

    assert {:error, :stale_source} =
             Cache.requirements(cache, acquire(entry.lexical_key), bounds(), quote_credit())

    assert {{:error, :stale_token}, ^cache, effects, _} =
             run(cache, {:publish, token, entry}, bounds(1, 9))

    assert length(effects) == length(refs(entry))
    {cache, effects} = drain_all(cache)
    assert [{:wake, _, _, :retired}] = effects
    assert_empty(cache)
  end

  test "ready payload retirement releases before deleting its slot even with pending waiters" do
    {entry, _} = entry()
    cache = cache()
    entry = %{entry | source_revision: cache.source_revision}
    {{:compute, token}, cache, _, _} = run(cache, acquire(entry.lexical_key))

    for _ <- 1..2, reduce: cache do
      cache ->
        {_, cache, _, _} = run(cache, acquire(entry.lexical_key))
        cache
    end
    |> then(fn cache ->
      {:published, cache, _, _} = run(cache, {:publish, token, entry})
      {_, cache, effects, _} = run(cache, :retire, bounds(1, 1))
      {cache, rest} = drain_all(cache)
      effects = effects ++ rest
      assert Enum.count(effects, &match?({:wake, _, _, :retired}, &1)) == 2

      assert Enum.sort(Enum.filter(effects, &match?({:release, _}, &1))) ==
               Enum.sort(Enum.map(refs(entry), &{:release, &1}))

      assert_empty(cache)
    end)
  end

  test "cancellation and owner DOWN use indexed obligations and never promote a producer" do
    cache = cache()
    owner = {make_ref(), make_ref()}
    first_key = key()
    second_key = key("text/css")
    {{:compute, _}, cache, _, _} = run(cache, acquire(first_key, owner))
    {{:compute, _}, cache, _, _} = run(cache, acquire(second_key, owner))
    {_, cache, _, _} = run(cache, acquire(first_key))
    {{:more, 1}, cache, [], _} = run(cache, {:cancel, elem(owner, 0), elem(owner, 1)})
    assert :gb_trees.size(cache.requests) == 2
    {{:done, 1}, cache, [], _} = run(cache, {:owner_down, elem(owner, 1)})
    {cache, effects} = drain_all(cache)
    assert [{:wake, _, _, :retry}] = effects
    assert_empty(cache)
  end

  test "waiter cancellation removes all reverse indexes without waking it" do
    cache = cache()
    {_, cache, _, _} = run(cache, acquire(key()))
    owner = {make_ref(), make_ref()}
    {_, cache, _, _} = run(cache, acquire(key(), owner))
    {_, cache, [], _} = run(cache, {:owner_down, elem(owner, 1)})
    assert :gb_trees.size(cache.requests) == 1
    assert :gb_trees.is_empty(cache.waiters)
    {_, cache, _, _} = run(cache, :retire, bounds(1, 9))
    assert_empty(cache)
  end

  test "eviction and cancellation can drain with zero new retained credit at capacity" do
    {entry, _} = entry()
    cache = cache(%{slots: 2, waiters: 2, key_bytes: 16_384})
    entry = %{entry | source_revision: cache.source_revision}
    {{:compute, token}, cache, _, _} = run(cache, acquire(entry.lexical_key))
    {_, cache, _, _} = run(cache, acquire(entry.lexical_key))
    {:published, cache, _, _} = run(cache, {:publish, token, entry})
    command = {:evict, entry.lexical_key}
    requirement = price(cache, command, bounds(1, 9))
    assert requirement.retained_bytes == 0
    assert requirement.workspace_bytes <= Cache.cleanup_workspace(cache)

    {:ok, cache, effects, _} =
      Cache.transition(cache, command, bounds(1, 9), credit(0, Cache.cleanup_workspace(cache)))

    assert length(effects) == length(refs(entry))
    {cache, [{:wake, _, _, :retry}]} = drain_all(cache)
    assert_empty(cache)
  end

  test "cleanup work depends on visits and index height, not retained key or analysis bytes" do
    cache = cache(%{slots: 50_000, waiters: 50_000, key_bytes: 1_000_000})
    owner = {make_ref(), make_ref()}
    {_, cache, _, _} = run(cache, acquire(key(), owner))
    baseline = price(cache, {:cancel, elem(owner, 0), elem(owner, 1)})
    large_key = {:html, "text/html", [{"private", String.duplicate("x", 200_000)}]}
    other = cache(%{slots: 50_000, waiters: 50_000, key_bytes: 1_000_000})
    {_, other, _, _} = run(other, acquire(large_key, owner))
    assert price(other, {:cancel, elem(owner, 0), elem(owner, 1)}) == baseline
    assert other.metadata_bytes > cache.metadata_bytes + 300_000
  end

  test "receipt lists and the full eleven-limit payload shape are bounded" do
    {entry, _} = entry()
    cache = cache()
    {{:compute, token}, cache, _, _} = run(cache, acquire(entry.lexical_key))

    for invalid <- [
          Map.put(entry, :response, :forbidden),
          %{entry | retained_receipts: for(_ <- 1..5, do: make_ref())},
          %{entry | root_ownership: :unknown},
          %{
            entry
            | analysis: %{entry.analysis | allocation: %{seed: entry.analysis.allocation.seed}}
          },
          %{
            entry
            | analysis: %{
                entry.analysis
                | limits: Map.delete(entry.analysis.limits, :max_xml_tokens)
              }
          }
        ] do
      assert {{:error, :invalid_entry}, ^cache, [], _} =
               Cache.transition(cache, {:publish, token, invalid}, bounds(1, 9), quote_credit())
    end
  end

  test "complete key backing is priced and rejected before admission when under cap" do
    backing = :binary.copy("h", 4096)
    value = binary_part(backing, 0, 80)
    key = {:html, "text/html", [{"link", value}]}
    assert {:ok, cost} = Retained.bytes(key, 20_000)
    cache = cache(%{slots: 2, waiters: 0, key_bytes: cost})
    price = price(cache, acquire(key))
    assert price.retained_bytes == 8192 + 2 * cost
    too_small = cache(%{slots: 2, waiters: 0, key_bytes: cost - 1})

    assert {:error, {:limit, :max_retained_bytes}} =
             Cache.requirements(too_small, acquire(key), bounds(), quote_credit())
  end

  test "replay preserves seed history and rejects a fresh seed despite retained receipts" do
    {entry, opts} = entry()
    seed = entry.analysis.allocation.seed
    assert seed.retained > 0
    assert seed.counts.facts > 0
    assert seed.peak > seed.retained

    assert {:error, :invalid_budget_continuation} =
             Analysis.cached_result(entry.analysis, opts, Budget.new(opts))

    assert {:ok, copy_bytes} = Retained.copy_bytes(entry, 8_000_000)
    assert {:ok, current} = Budget.charge(seed, copy_bytes)
    assert {:ok, rebound} = Analysis.cached_result(entry.analysis, opts, current)
    assert rebound.budget.counts.facts >= seed.counts.facts
    assert rebound.budget.peak >= seed.peak
    assert rebound.budget.scratch == 0
    assert entry.analysis.allocation.seed === seed

    for name <- Map.keys(entry.analysis.limits) do
      assert {:error, _} = Analysis.cached_result(entry.analysis, Map.delete(opts, name), current)
    end

    corrupted = %{
      entry.analysis
      | budget: %{entry.analysis.budget | retained: entry.analysis.budget.retained + 1}
    }

    assert {:error, :invalid_cached_analysis} = Analysis.cached_result(corrupted, opts, current)
  end

  test "the explicit Charset marker is retained for borrowed and converted roots" do
    for {body, options, expected} <- [
          {String.duplicate("plain ", 20), %{content_type: "text/plain", headers: []}, :borrowed},
          {<<255, 254, 65, 0, 66, 0>>, %{content_type: "application/xml", headers: []}, :retained}
        ] do
      {:ok, limits} = Limits.new(%{})
      options = Map.merge(limits, options)

      assert {:ok, decoded, seed, ^expected} =
               Charset.decode_owned_result(body, options, Budget.new(limits))

      assert {:ok, analysis} = Analysis.analyze(decoded, options, seed)
      assert analysis.allocation.seed == seed
      cache = cache()

      capsule = %{
        source_revision: cache.source_revision,
        lexical_key: analysis.lexical_key,
        analysis: analysis,
        root_ownership: expected,
        retained_receipts: [],
        backing_receipts: [make_ref()],
        copy_receipt: make_ref()
      }

      {{:compute, token}, cache, _, _} = run(cache, acquire(analysis.lexical_key))
      {:published, cache, _, _} = run(cache, {:publish, token, capsule})
      {{:candidate, candidate}, _, _, _} = run(cache, acquire(analysis.lexical_key))
      assert candidate.root_ownership == expected
      assert :erts_debug.same(candidate.analysis, analysis)
    end
  end

  test "publication and one-visit cleanup stay within the native mutation and effect bounds" do
    cache = cache(%{slots: 40, waiters: 80, key_bytes: 16_384})
    {entry, _} = entry()
    entry = %{entry | source_revision: cache.source_revision}
    {{:compute, token}, cache, _, _} = run(cache, acquire(entry.lexical_key))

    cache =
      Enum.reduce(1..40, cache, fn _, cache ->
        {_, cache, _, _} = run(cache, acquire(entry.lexical_key))
        cache
      end)

    {response, mutations} = native_mutations(fn -> run(cache, {:publish, token, entry}) end)
    {:published, cache, [], _} = response
    assert mutations <= 32
    {response, mutations} = native_mutations(fn -> run(cache, {:drain, 1}, bounds(1, 1)) end)
    {{:more, 1}, cache, [_], _} = response
    assert mutations <= 32
    assert :gb_trees.size(cache.waiters) == 39
    {cache, _} = drain_all(cache)
    {response, mutations} = native_mutations(fn -> run(cache, :retire, bounds(1, 9)) end)
    {{:done, 1}, cache, effects, _} = response
    assert mutations <= 32
    assert length(effects) <= 9
    assert_empty(cache)
  end

  test "deterministic mixed cancellation and retirement leave no obsolete ownership" do
    Enum.each(1..12, fn round ->
      cache = cache(%{slots: 4, waiters: 20, key_bytes: 16_384})
      owners = for _ <- 1..4, do: {make_ref(), make_ref()}
      keys = for i <- 1..4, do: {:html, "text/html", [{"link", Integer.to_string(i)}]}

      cache =
        Enum.reduce(Enum.zip(keys, owners), cache, fn {key, owner}, cache ->
          {_, cache, _, _} = run(cache, acquire(key, owner))

          Enum.reduce(owners, cache, fn other, cache ->
            if other == owner do
              cache
            else
              {_, cache, _, _} = run(cache, acquire(key, other))
              cache
            end
          end)
        end)

      owner = Enum.at(owners, rem(round, 4))
      {_, cache, _, _} = run(cache, {:owner_down, elem(owner, 1)}, bounds(2, 0))
      {_, cache, effects, _} = run(cache, :retire, bounds(1, 1))
      {cache, more} = drain_all(cache)
      assert length(effects ++ more) <= 12
      assert_empty(cache)
    end)
  end

  test "a full cache can retire with no new metadata credit and its reserved small batch" do
    cache = cache(%{slots: 32, waiters: 32, key_bytes: 16_384})
    lease = make_ref()
    keys = for i <- 1..32, do: {:html, "text/html", [{"link", Integer.to_string(i)}]}

    cache =
      Enum.reduce(keys, cache, fn key, cache ->
        {_, cache, _, _} = run(cache, acquire(key, {make_ref(), lease}))
        {_, cache, _, _} = run(cache, acquire(key, {make_ref(), lease}))
        cache
      end)

    assert :gb_trees.size(cache.slots) == cache.caps.slots
    assert :gb_trees.size(cache.waiters) == cache.caps.waiters
    command = {:owner_down, lease}
    assert price(cache, command).retained_bytes == 0
    reserve = Cache.cleanup_workspace(cache)

    {response, mutations} =
      native_mutations(fn ->
        Cache.transition(cache, command, bounds(), credit(0, reserve))
      end)

    {{:more, 1}, cache, [], _} = response
    assert mutations <= 32
    assert price(cache, :retire, bounds(1, 9)).workspace_bytes <= reserve
    {_, cache, effects, _} = Cache.transition(cache, :retire, bounds(1, 9), credit(0, reserve))
    {cache, more} = drain_all(cache)
    assert length(effects ++ more) <= 32
    assert_empty(cache)
  end

  test "quote credit is checked before invoking the real bounded key measurer" do
    :erlang.trace_pattern({Retained, :bytes, 2}, true, [:call_count])

    try do
      assert {:error, :unfunded_workspace} =
               Cache.requirements(cache(), acquire(key()), bounds(), credit(0, 0))

      assert {:call_count, 0} = :erlang.trace_info({Retained, :bytes, 2}, :call_count)
    after
      :erlang.trace_pattern({Retained, :bytes, 2}, false, [:call_count])
    end
  end

  test "all eleven stricter replay limits fail without running lexical analysis again" do
    {entry, opts} = entry()
    assert map_size(entry.analysis.limits) == 11
    {:ok, copy} = Retained.copy_bytes(entry, 8_000_000)
    {:ok, current} = Budget.charge(entry.analysis.allocation.seed, copy)
    :erlang.trace_pattern({Crawler.Analysis.Lexical, :run, 4}, true, [:call_count])

    try do
      assert {:ok, rebound} = Analysis.cached_result(entry.analysis, opts, current)
      assert rebound.regions === entry.analysis.regions

      for {name, value} <- entry.analysis.limits do
        assert {:error, {:limit, {:cached_analysis, ^name}}} =
                 Analysis.cached_result(entry.analysis, Map.put(opts, name, value - 1), current)
      end

      assert {:call_count, 0} =
               :erlang.trace_info({Crawler.Analysis.Lexical, :run, 4}, :call_count)
    after
      :erlang.trace_pattern({Crawler.Analysis.Lexical, :run, 4}, false, [:call_count])
    end
  end

  test "native index growth including rebalances fits the quoted structural credit" do
    cache = cache(%{slots: 128, waiters: 0, key_bytes: 16_384})
    owner = {make_ref(), make_ref()}
    :erlang.trace_pattern({:gb_trees, :balance, 2}, true, [:local, :call_count])

    try do
      cache =
        Enum.reduce(1..128, cache, fn i, cache ->
          key = {:html, "text/html", [{"link", Integer.to_string(i)}]}
          command = acquire(key, owner)
          price = price(cache, command)
          input = {cache, command}
          before = 8 * :erts_debug.size(input)
          {response, mutations} = native_mutations(fn -> run(cache, command) end)
          {{:compute, _}, next, [], _} = response
          extra = 8 * :erts_debug.size({input, response}) - before
          assert extra <= price.retained_bytes + price.workspace_bytes
          assert mutations <= 32
          assert next.metadata_bytes <= 4096 + 128 * (8192 + 2 * 16_384)
          next
        end)

      assert :gb_trees.size(cache.slots) == 128
      assert {:call_count, rebalances} = :erlang.trace_info({:gb_trees, :balance, 2}, :call_count)
      assert rebalances > 0
    after
      :erlang.trace_pattern({:gb_trees, :balance, 2}, false, [:local, :call_count])
    end
  end

  test "real HTML XML CSS and JavaScript facts survive immutable cache adoption" do
    for {body, type, goal} <- [
          {"<a href='next'>x</a>", "text/html", :module},
          {"<r href='next'/>", "application/xml", :module},
          {"a { background: url('x.png') }", "text/css", :module},
          {"fetch('./x')", "text/javascript", :module},
          {"fetch('./x')", "text/javascript", :script}
        ] do
      {:ok, limits} = Limits.new(%{max_total_bytes: 8_000_000})
      options = Map.merge(limits, %{content_type: type, headers: [], javascript_goal: goal})
      {:ok, seed} = Budget.charge(Budget.new(limits), 2048, facts: 2)
      assert {:ok, analysis} = Analysis.analyze(body, options, seed)
      cache = cache()

      entry = %{
        source_revision: cache.source_revision,
        lexical_key: analysis.lexical_key,
        analysis: analysis,
        root_ownership: :borrowed,
        retained_receipts: [make_ref()],
        backing_receipts: [make_ref()],
        copy_receipt: make_ref()
      }

      {{:compute, token}, cache, _, _} = run(cache, acquire(analysis.lexical_key))
      {:published, cache, _, _} = run(cache, {:publish, token, entry})
      {{:candidate, candidate}, _, _, _} = run(cache, acquire(analysis.lexical_key))
      {:ok, copy} = Retained.copy_bytes(candidate, 8_000_000)
      {:ok, current} = Budget.charge(seed, copy)
      assert {:ok, adopted} = Analysis.cached_result(candidate.analysis, options, current)
      assert :erts_debug.same(candidate.analysis, analysis)
      assert adopted.regions === analysis.regions
      assert adopted.budget.counts === analysis.budget.counts
      assert adopted.budget.retained >= current.retained + analysis.allocation.retained
    end
  end

  test "oversized equal-prefix hit eviction and publication keys fail before any native lookup" do
    {original, opts} = entry()
    headers = List.duplicate({"prefix", "value"}, 256)
    opts = %{opts | headers: headers}
    {:ok, analysis} = Analysis.analyze("plain", opts, original.analysis.allocation.seed)
    key = analysis.lexical_key
    {:ok, key_bytes} = Retained.bytes(key, 2_000_000)
    cache = cache(%{slots: 2, waiters: 2, key_bytes: key_bytes})

    capsule = %{
      original
      | source_revision: cache.source_revision,
        analysis: analysis,
        lexical_key: key
    }

    {{:compute, token}, cache, _, _} = run(cache, acquire(key))
    {:published, cache, _, _} = run(cache, {:publish, token, capsule})
    oversized = put_elem(key, 2, headers ++ List.duplicate({"prefix", "value"}, 1024))

    {:ok, oversized_analysis} =
      Analysis.analyze(
        "plain",
        %{opts | headers: elem(oversized, 2)},
        original.analysis.allocation.seed
      )

    oversized_entry = %{
      capsule
      | analysis: oversized_analysis,
        lexical_key: oversized,
        copy_receipt: make_ref()
    }

    :erlang.trace_pattern({:gb_trees, :lookup, 2}, true, [:call_count])

    try do
      for command <- [acquire(oversized), {:evict, oversized}, {:publish, token, oversized_entry}] do
        assert {:error, {:limit, :max_retained_bytes}} =
                 Cache.requirements(cache, command, bounds(), quote_credit())

        assert {{:error, {:limit, :max_retained_bytes}}, same, [],
                %{visited: 0, metadata_delta: 0}} =
                 Cache.transition(
                   cache,
                   command,
                   bounds(),
                   credit(0, Cache.cleanup_workspace(cache))
                 )

        assert :erts_debug.same(same, cache)
      end

      assert {:call_count, 0} = :erlang.trace_info({:gb_trees, :lookup, 2}, :call_count)
    after
      :erlang.trace_pattern({:gb_trees, :lookup, 2}, false, [:call_count])
    end

    assert {{:candidate, ^capsule}, _, [], _} = run(cache, acquire(key))
    assert price(cache, {:evict, key}, bounds(1, 9)).key_walk_steps_upper > 0
  end

  test "real canonical atom charlist and ignored numeric header names remain exact" do
    {original, options} = entry()

    header_lists = [
      [{:link, "<a.css>; rel=stylesheet"}],
      [{~c"link", "<b.css>; rel=stylesheet"}],
      [{1234, "ignored integer name"}],
      [{1234.5, "ignored float name"}]
    ]

    {cache, entries} =
      Enum.reduce(header_lists, {cache(), []}, fn headers, {cache, entries} ->
        opts = %{options | headers: headers}
        {:ok, canonical, _} = Analysis.lexical_key_result(opts, Budget.new(opts))

        assert {:ok, analysis} =
                 Analysis.analyze("plain", opts, original.analysis.allocation.seed)

        assert analysis.lexical_key === canonical
        assert :erts_debug.same(elem(analysis.lexical_key, 2), headers)

        entry = %{
          original
          | source_revision: cache.source_revision,
            lexical_key: analysis.lexical_key,
            analysis: analysis,
            copy_receipt: make_ref(),
            retained_receipts: [make_ref()],
            backing_receipts: [make_ref()]
        }

        {{:compute, token}, cache, _, _} = run(cache, acquire(entry.lexical_key))
        {:published, cache, [], _} = run(cache, {:publish, token, entry})
        {cache, [entry | entries]}
      end)

    assert :gb_trees.size(cache.slots) == 4

    for entry <- entries do
      {{:candidate, candidate}, same, [], _} = run(cache, acquire(entry.lexical_key))
      assert :erts_debug.same(same, cache)
      assert :erts_debug.same(candidate, entry)
      assert :erts_debug.same(candidate.lexical_key, entry.analysis.lexical_key)

      assert :erts_debug.same(
               candidate.analysis.source_options.headers,
               elem(entry.lexical_key, 2)
             )

      refute Map.has_key?(candidate, :headers)
      refute Map.has_key?(cache, :headers)
      refute Map.has_key?(cache, :request)
      refute Map.has_key?(cache, :response)
    end

    cache =
      Enum.reduce(entries, cache, fn entry, cache ->
        {:ok, next, effects, _} = run(cache, {:evict, entry.lexical_key}, bounds(1, 9))
        assert Enum.sort(effects) == Enum.sort(Enum.map(refs(entry), &{:release, &1}))
        next
      end)

    assert_empty(cache)
  end

  test "native numeric ordering aliases cannot hit wait on or evict another canonical key" do
    {original, options} = entry()
    opts = %{options | headers: [{1, "ignored"}]}
    alias_opts = %{options | headers: [{1.0, "ignored"}]}
    {:ok, key, _} = Analysis.lexical_key_result(opts, Budget.new(opts))
    {:ok, alias_key, _} = Analysis.lexical_key_result(alias_opts, Budget.new(alias_opts))
    {:ok, analysis} = Analysis.analyze("plain", opts, original.analysis.allocation.seed)
    assert key == alias_key
    refute key === alias_key
    cache = cache()

    entry = %{
      original
      | source_revision: cache.source_revision,
        lexical_key: key,
        analysis: analysis
    }

    {{:compute, token}, computing, [], _} = run(cache, acquire(key))
    {:published, ready, [], _} = run(computing, {:publish, token, entry})

    for cache <- [computing, ready], command <- [acquire(alias_key), {:evict, alias_key}] do
      assert {:error, :lexical_key_collision} =
               Cache.requirements(cache, command, bounds(), quote_credit())

      assert {{:error, :lexical_key_collision}, same, [], %{visited: 0, metadata_delta: 0}} =
               Cache.transition(cache, command, bounds(), quote_credit())

      assert :erts_debug.same(same, cache)
    end

    {{:candidate, candidate}, same, [], _} = run(ready, acquire(key))
    assert :erts_debug.same(candidate, entry)
    assert :erts_debug.same(same, ready)
    {:ok, empty, _, _} = run(ready, {:evict, key}, bounds(1, 9))
    assert_empty(empty)
  end

  test "malformed and unfunded canonical caller keys never enter native indexes" do
    {entry, _} = entry()
    cache = cache()
    entry = %{entry | source_revision: cache.source_revision}
    {{:compute, token}, cache, _, _} = run(cache, acquire(entry.lexical_key))
    {:published, cache, _, _} = run(cache, {:publish, token, entry})

    malformed = [
      {:invalid_mode, "text/html", []},
      {:html, :invalid_type, []},
      {:html, "text/html", :not_a_list},
      {:html, "text/html", [{:link, "x"} | :not_a_list]}
    ]

    :erlang.trace_pattern({:gb_trees, :lookup, 2}, true, [:call_count])

    try do
      for key <- malformed, command <- [acquire(key), {:evict, key}] do
        assert {:error, :invalid_lexical_key} =
                 Cache.requirements(cache, command, bounds(), quote_credit())

        assert {{:error, :invalid_lexical_key}, same, [], %{visited: 0, metadata_delta: 0}} =
                 Cache.transition(
                   cache,
                   command,
                   bounds(),
                   credit(0, Cache.cleanup_workspace(cache))
                 )

        assert :erts_debug.same(same, cache)
      end

      for command <- [acquire(entry.lexical_key), {:evict, entry.lexical_key}] do
        assert {:error, :unfunded_workspace} =
                 Cache.requirements(cache, command, bounds(), credit(0, 0))

        assert {{:error, :unfunded_workspace}, same, [], %{visited: 0, metadata_delta: 0}} =
                 Cache.transition(cache, command, bounds(), credit(0, 0))

        assert :erts_debug.same(same, cache)
      end

      assert {:call_count, 0} = :erlang.trace_info({:gb_trees, :lookup, 2}, :call_count)
    after
      :erlang.trace_pattern({:gb_trees, :lookup, 2}, false, [:call_count])
    end
  end

  defp cache(caps \\ %{slots: 8, waiters: 16, key_bytes: 16_384}) do
    {:ok, cache} = Cache.new(make_ref(), caps, credit(4096, 4096))
    cache
  end

  defp key(type \\ "text/html") do
    {:ok, limits} = Limits.new(%{})

    {:ok, key, _} =
      Analysis.lexical_key_result(%{content_type: type, headers: []}, Budget.new(limits))

    key
  end

  defp acquire(key, {target, lease} \\ {make_ref(), make_ref()}),
    do: {:acquire, key, target, lease, make_ref()}

  defp bounds(visits \\ 1, effects \\ 0), do: %{max_visits: visits, max_effects: effects}
  defp credit(retained, workspace), do: %{retained_bytes: retained, workspace_bytes: workspace}
  defp quote_credit, do: credit(0, 100_000)

  defp price(cache, command, bounds \\ bounds()) do
    {:ok, price} = Cache.requirements(cache, command, bounds, quote_credit())
    price
  end

  defp run(cache, command, bounds \\ bounds()) do
    price = price(cache, command, bounds)
    Cache.transition(cache, command, bounds, credit(price.retained_bytes, price.workspace_bytes))
  end

  defp entry do
    {:ok, limits} = Limits.new(%{max_total_bytes: 8_000_000})

    opts =
      Map.merge(limits, %{content_type: "text/html", headers: [{"private", "retained exactly"}]})

    {:ok, seed} = Budget.charge(Budget.new(limits), 2048, facts: 3)
    {:ok, seed} = Budget.reserve(seed, 8192)
    {:ok, seed} = Budget.release(seed, 8192)
    {:ok, analysis} = Analysis.analyze("plain source", opts, seed)

    {%{
       source_revision: make_ref(),
       lexical_key: analysis.lexical_key,
       analysis: analysis,
       root_ownership: :borrowed,
       retained_receipts: [make_ref()],
       backing_receipts: [make_ref()],
       copy_receipt: make_ref()
     }, opts}
  end

  defp refs(entry),
    do: Enum.uniq([entry.copy_receipt | entry.retained_receipts ++ entry.backing_receipts])

  defp drain_all(cache, effects \\ [], left \\ 200) do
    assert left > 0

    case run(cache, {:drain, 1}, bounds(1, 9)) do
      {{:done, _}, cache, more, _} -> {cache, effects ++ more}
      {{:more, _}, cache, more, _} -> drain_all(cache, effects ++ more, left - 1)
    end
  end

  defp assert_empty(cache) do
    assert :gb_trees.is_empty(cache.keys)
    assert :gb_trees.is_empty(cache.slots)
    assert :gb_trees.is_empty(cache.waiters)
    assert :gb_trees.is_empty(cache.requests)
    assert :gb_trees.is_empty(cache.leases)
    assert cache.head == nil
    assert cache.tail == nil
    assert cache.metadata_bytes == 4096
  end

  defp native_mutations(callback) do
    calls =
      for name <- [:insert, :update, :delete],
          do: {:gb_trees, name, 3 - if(name == :delete, do: 1, else: 0)}

    for call <- calls, do: :erlang.trace_pattern(call, true, [:call_count])

    try do
      result = callback.()

      mutations =
        Enum.reduce(calls, 0, fn call, total ->
          {:call_count, count} = :erlang.trace_info(call, :call_count)
          total + count
        end)

      {result, mutations}
    after
      for call <- calls, do: :erlang.trace_pattern(call, false, [:call_count])
    end
  end
end
