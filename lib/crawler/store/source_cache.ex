defmodule Crawler.Store.SourceCache do
  @moduledoc """
  Pure, owner-funded lexical slots for one existing physical source slot.

  The host fences source/proof/lease liveness and all grants before each call.
  A candidate is borrowed locally, not permission to transfer or replay it.
  Payload checks establish bounded shape only. The host supplies a trusted ending
  certificate and validates the continuing seed floor with Analysis.cached_result/3.
  The exact private Analysis, including its original allocation seed and headers,
  is kept unchanged. This module neither validates funding nor constructs seeds.

  `prepaid` asserts host-owned credit for this call only. Retained metadata and
  workspace are separate from complete entry-copy and binary/semantic receipts.
  Effects request release of this capsule's ownership; the host must preserve
  other live ownership of shared receipts and enforce one-shot incoming transfers.
  No effect directly revokes a Resources grant. Main drops replaced state and
  consumed effects before reusing workspace or refunding released metadata.

  `caps` contains only `slots`, `waiters`, and complete `key_bytes`. Their sum of
  counts is at most 134217727; the full metadata tariff must fit a small integer.
  `bounds` contains only `max_visits` and `max_effects`. A visit handles one slot
  or indexed obligation; it is not a claim about native tree node visits.
  `prepaid` contains only `retained_bytes` and `workspace_bytes`, each numeric and
  scoped to the current call. No field proves a live grant or rolls credit forward.

  Quote workspace is 4096 + 256H, plus 69632 for acquire/evict/publish key measurement.
  The key walk finishes before index access and structural growth. Transition
  workspace is the maximum of that quote and 4096 + 256H +
  256(2H+1)*32V + 1024*32V + 256R + 1024E. H uses live
  counts plus command growth, capped by the configured historical height bound.
  R sums current sizes plus one of indexes that can receive an insertion,
  including nested owner rings; cleanup has R=0. V and E are command-specific
  visit/effect bounds. Retained metadata M and entry/key backing are not copied
  into this workspace tariff. The implementation bounds local mutation count
  by 32 per visit and reports a separate conservative native node work bound.
  Key comparisons use only bounded keys; twice `key_bytes` per native node is a
  coarse byte-comparison bound, distinct from logical visits and walker steps.

  Each slot costs 8192 plus twice its bounded complete key measurement; each
  waiter costs 8192; the fixed root costs 4096. These allowances include request,
  lease, nested reference-ring and native tree nodes. Records have at most twelve
  fixed fields; no variable metadata other than the key and bounded receipt lists
  is retained. Key backing is conservatively charged even when already shared.

  Native indexes use OTP gb_trees. Cleanup deletes or updates existing nodes and
  cannot rebalance. An acquire also reserves rebalance workspace from the current
  sizes of only the indexes it may insert into. No old key or payload is copied by
  owner-local updates. Main must prepay and keep a one-visit cleanup reserve apart
  from metadata capacity; `cleanup_workspace/1` returns its bound without a walk.
  """

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Store.Retained

  require Record

  Record.defrecordp(:slot,
    id: nil,
    key: nil,
    key_bytes: 0,
    status: :computing,
    token: nil,
    entry: nil,
    waiters: {0, nil},
    previous: nil,
    following: nil,
    queued: false
  )

  @root_bytes 4096
  @obligation_bytes 8192
  @key_workspace 69_632
  @max_count 134_217_727
  @max_bytes 576_460_752_303_423_487
  @limits [
    :max_bytes,
    :max_total_bytes,
    :max_regions,
    :max_depth,
    :max_facts,
    :max_occurrences,
    :max_edits,
    :max_output_bytes,
    :max_xml_depth,
    :max_xml_tokens,
    :max_xml_attributes
  ]

  @type caps :: %{slots: pos_integer(), waiters: non_neg_integer(), key_bytes: pos_integer()}
  @type bounds :: %{max_visits: non_neg_integer(), max_effects: non_neg_integer()}
  @type prepaid :: %{retained_bytes: non_neg_integer(), workspace_bytes: non_neg_integer()}
  @type token :: {reference(), reference(), reference(), reference(), reference()}
  @type entry :: %{
          source_revision: reference(),
          lexical_key: term(),
          analysis: %Analysis{},
          root_ownership: :borrowed | :retained,
          retained_receipts: [reference()],
          backing_receipts: [reference()],
          copy_receipt: reference()
        }

  @derive {Inspect, only: [:status, :metadata_bytes]}
  @enforce_keys [:source_revision, :caps]
  defstruct [
    :source_revision,
    :caps,
    status: :live,
    keys: {0, nil},
    slots: {0, nil},
    waiters: {0, nil},
    requests: {0, nil},
    leases: {0, nil},
    head: nil,
    tail: nil,
    metadata_bytes: @root_bytes
  ]

  @type t :: %__MODULE__{}
  @type command ::
          {:acquire, term(), reference(), reference(), reference()}
          | {:publish, token(), entry()}
          | {:cancel, reference(), reference()}
          | {:owner_down, reference()}
          | {:evict, term()}
          | :retire
          | {:drain, non_neg_integer()}
  @type effect ::
          {:release, reference()}
          | {:wake, reference(), reference(), :ready | :retry | :retired}
  @type result ::
          :ok
          | :published
          | {:compute, token()}
          | {:waiting, reference()}
          | {:candidate, entry()}
          | {:done | :more, non_neg_integer()}
          | {:error, term()}
  @type requirement :: %{
          retained_bytes: non_neg_integer(),
          workspace_bytes: non_neg_integer(),
          max_visits: non_neg_integer(),
          max_effects: non_neg_integer(),
          key_walk_steps_upper: non_neg_integer(),
          index_nodes_upper: non_neg_integer()
        }
  @type statistics :: %{
          visited: non_neg_integer(),
          metadata_delta: integer(),
          index_mutations_upper: non_neg_integer()
        }

  @spec new(reference(), caps(), prepaid()) :: {:ok, t()} | {:error, atom()}
  def new(revision, caps, prepaid) do
    with true <- is_reference(revision) || {:error, :invalid_source_revision},
         :ok <- valid_caps(caps),
         :ok <- funded(prepaid, @root_bytes, @root_bytes) do
      {:ok, %__MODULE__{source_revision: revision, caps: caps}}
    end
  end

  @doc "Permanent host reserve for one cleanup visit with up to ten effects."
  @spec cleanup_workspace(t()) :: non_neg_integer()
  def cleanup_workspace(%__MODULE__{} = cache) do
    workspace(height_cap(cache), 1, 10, 0, false)
  end

  @doc "A bounded preflight; it does not establish receipt or lease authority."
  @spec requirements(t(), command(), bounds(), prepaid()) ::
          {:ok, requirement()} | {:error, term()}
  def requirements(%__MODULE__{} = cache, command, bounds, prepaid) do
    with :ok <- valid_bounds(cache, bounds),
         :ok <- funded(prepaid, 0, quote_workspace(cache, command)),
         {:ok, plan} <- plan(cache, command, bounds) do
      {:ok, prices(cache, command, bounds, plan)}
    end
  end

  @spec transition(t(), command(), bounds(), prepaid()) ::
          {result(), t(), [effect()], statistics()}
  def transition(%__MODULE__{} = cache, command, bounds, prepaid) do
    with :ok <- valid_bounds(cache, bounds),
         :ok <- funded(prepaid, 0, quote_workspace(cache, command)),
         {:ok, plan} <- plan(cache, command, bounds),
         price = prices(cache, command, bounds, plan),
         :ok <- funded(prepaid, price.retained_bytes, price.workspace_bytes) do
      {result, next, effects, visited} = execute(cache, command, plan, bounds)

      {result, next, effects,
       %{
         visited: visited,
         metadata_delta: next.metadata_bytes - cache.metadata_bytes,
         index_mutations_upper: 32 * max(visited, 1)
       }}
    else
      {:error, reason} ->
        {{:error, reason}, cache, [], %{visited: 0, metadata_delta: 0, index_mutations_upper: 0}}
    end
  end

  defp valid_caps(%{slots: s, waiters: w, key_bytes: k} = caps)
       when map_size(caps) == 3 and is_integer(s) and s > 0 and s <= @max_count and
              is_integer(w) and w >= 0 and w <= @max_count and s + w <= @max_count and
              is_integer(k) and k > 0 and k <= @max_bytes and
              @root_bytes + @obligation_bytes * (s + w) + 2 * k * s <= @max_bytes,
       do: :ok

  defp valid_caps(_), do: {:error, :invalid_caps}

  defp valid_bounds(cache, %{max_visits: v, max_effects: e} = bounds)
       when map_size(bounds) == 2 and is_integer(v) and v >= 0 and
              is_integer(e) and e >= 0 do
    if v <= cache.caps.slots + cache.caps.waiters + 1 and e <= 10 * v + 9,
      do: :ok,
      else: {:error, :invalid_bounds}
  end

  defp valid_bounds(_, _), do: {:error, :invalid_bounds}

  defp funded(%{retained_bytes: r, workspace_bytes: w} = prepaid, need_r, need_w)
       when map_size(prepaid) == 2 and is_integer(r) and r >= 0 and r <= @max_bytes and
              is_integer(w) and w >= 0 and w <= @max_bytes do
    cond do
      r < need_r -> {:error, :unfunded_metadata}
      w < need_w -> {:error, :unfunded_workspace}
      true -> :ok
    end
  end

  defp funded(_, _, _), do: {:error, :invalid_prepaid}

  defp height_cap(cache), do: 2 * bits(cache.caps.slots + cache.caps.waiters) + 2
  defp bits(0), do: 0
  defp bits(n), do: 1 + bits(div(n, 2))

  defp height(cache, growth),
    do: min(size(cache.slots) + size(cache.waiters) + growth, height_cap(cache))

  defp quote_workspace(cache, command),
    do:
      4096 + 256 * height(cache, if(acquire?(command), do: 1, else: 0)) +
        if(key_command?(command), do: @key_workspace, else: 0)

  defp acquire?({:acquire, _, _, _, _}), do: true
  defp acquire?(_), do: false

  defp key_command?({:evict, _}), do: true
  defp key_command?({:publish, _, _}), do: true
  defp key_command?(command), do: acquire?(command)

  defp workspace(h, visits, effects, rebalance, key?) do
    base = 4096 + 256 * h
    walk = base + if(key?, do: @key_workspace, else: 0)

    structural =
      base + 256 * (2 * h + 1) * 32 * visits + 1024 * 32 * visits +
        256 * rebalance + 1024 * effects

    max(walk, structural)
  end

  defp prices(cache, command, bounds, {kind, cost, rebalance, data}) do
    visits =
      cond do
        kind == :retire and size(cache.slots) == 0 -> 0
        kind in [:cancel, :owner_down, :retire] -> bounds.max_visits
        kind == :drain -> elem(command, 1)
        true -> 1
      end

    effects =
      case kind do
        :stale_publish -> length(data)
        :evict -> length(receipts(slot(data, :entry)))
        name when name in [:retire, :drain] -> min(bounds.max_effects, 10 * visits)
        _ -> 0
      end

    growth = if cost > 0, do: 1, else: 0
    h = height(cache, growth)

    %{
      retained_bytes: cost,
      workspace_bytes:
        max(
          quote_workspace(cache, command),
          workspace(h, visits, effects, rebalance, key_command?(command))
        ),
      max_visits: visits,
      max_effects: effects,
      key_walk_steps_upper: if(key_command?(command), do: 400_004, else: 0),
      index_nodes_upper: 32 * max(visits, 1) * (8 * rebalance + 4 * h + 1)
    }
  end

  defp plan(cache, {:acquire, key, target, lease, attempt}, bounds)
       when is_reference(target) and is_reference(lease) and is_reference(attempt) do
    cond do
      cache.status != :live ->
        {:error, :stale_source}

      bounds.max_visits == 0 ->
        {:error, :visit_capacity}

      true ->
        with {:ok, bytes} <- bounded_key(cache, key) do
          if lookup(cache.slots, attempt) != nil or lookup(cache.waiters, attempt) != nil,
            do: {:error, :duplicate_attempt},
            else: acquire_plan(cache, key, target, lease, bytes)
        end
    end
  end

  defp plan(cache, {:publish, token, entry}, bounds) do
    with :ok <- visit(bounds),
         :ok <- valid_entry(entry),
         {:ok, _bytes} <- bounded_key(cache, entry.lexical_key),
         true <- entry.analysis.lexical_key === entry.lexical_key || {:error, :invalid_entry} do
      case token_slot(cache, token) do
        {:ok, slot} when slot(slot, :status) == :computing ->
          if entry.source_revision == cache.source_revision and
               entry.lexical_key === slot(slot, :key),
             do: {:ok, {:publish, 0, 0, slot}},
             else: stale_plan(cache, token, entry, bounds)

        _ ->
          stale_plan(cache, token, entry, bounds)
      end
    end
  end

  defp plan(_cache, {:cancel, target, lease}, _bounds)
       when is_reference(target) and is_reference(lease),
       do: {:ok, {:cancel, 0, 0, nil}}

  defp plan(_cache, {:owner_down, lease}, _bounds) when is_reference(lease),
    do: {:ok, {:owner_down, 0, 0, nil}}

  defp plan(cache, {:evict, key}, bounds) do
    with :ok <- visit(bounds), {:ok, _bytes} <- bounded_key(cache, key) do
      case lookup(cache.keys, key) do
        nil ->
          {:ok, {:absent, 0, 0, nil}}

        id ->
          slot = get(cache.slots, id)

          with true <- slot(slot, :key) === key || {:error, :lexical_key_collision},
               :ok <- effect_capacity(bounds, length(receipts(slot(slot, :entry)))),
               do: {:ok, {:evict, 0, 0, slot}}
      end
    end
  end

  defp plan(_cache, :retire, _bounds), do: {:ok, {:retire, 0, 0, nil}}

  defp plan(_cache, {:drain, n}, bounds) when is_integer(n) and n >= 0 do
    if n <= bounds.max_visits,
      do: {:ok, {:drain, 0, 0, nil}},
      else: {:error, :invalid_bounds}
  end

  defp plan(_, _, _), do: {:error, :invalid_command}

  defp visit(%{max_visits: n}) when n > 0, do: :ok
  defp visit(_), do: {:error, :visit_capacity}
  defp effect_capacity(%{max_effects: n}, need) when n >= need, do: :ok
  defp effect_capacity(_, _), do: {:error, :effect_capacity}

  defp acquire_plan(cache, key, target, lease, bytes) do
    owner = {target, lease}

    case lookup(cache.keys, key) do
      nil ->
        with true <-
               size(cache.slots) < cache.caps.slots || {:error, {:limit, :source_cache_slots}} do
          rebalance = 2 * (size(cache.slots) + 1) + owner_insert_sizes(cache, owner)
          {:ok, {:compute, @obligation_bytes + 2 * bytes, rebalance, bytes}}
        end

      id ->
        slot = get(cache.slots, id)

        cond do
          slot(slot, :key) !== key ->
            {:error, :lexical_key_collision}

          slot(slot, :status) == :ready ->
            {:ok, {:candidate, 0, 0, slot(slot, :entry)}}

          slot(slot, :status) != :computing ->
            {:error, :source_busy}

          lookup(request(cache, owner), id) != nil ->
            {:error, :duplicate_request}

          size(cache.waiters) >= cache.caps.waiters ->
            {:error, {:limit, :source_cache_waiters}}

          true ->
            rebalance =
              size(cache.waiters) + 1 + size(slot(slot, :waiters)) + 1 +
                owner_insert_sizes(cache, owner)

            {:ok, {:wait, @obligation_bytes, rebalance, slot}}
        end
    end
  end

  defp owner_insert_sizes(cache, {_target, lease} = owner) do
    case lookup(cache.requests, owner) do
      nil ->
        lease_ring = lookup(cache.leases, lease) || empty()

        size(cache.requests) + 1 + 1 + size(lease_ring) + 1 +
          if(lookup(cache.leases, lease) == nil, do: size(cache.leases) + 1, else: 0)

      ring ->
        size(ring) + 1
    end
  end

  defp bounded_key(cache, key) do
    with :ok <- key_shape(key),
         {:ok, bytes} <- Retained.bytes(key, cache.caps.key_bytes),
         true <- proper_list?(elem(key, 2)) || {:error, :invalid_lexical_key},
         do: {:ok, bytes}
  end

  defp key_shape({mode, type, headers})
       when (is_binary(type) or type == :javascript) and is_list(headers) do
    if mode in [
         :html,
         :xml,
         :json,
         {:css, :stylesheet},
         {:javascript, :module},
         {:javascript, :script}
       ],
       do: :ok,
       else: {:error, :invalid_lexical_key}
  end

  defp key_shape(_), do: {:error, :invalid_lexical_key}
  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false

  defp stale_plan(cache, token, entry, bounds) do
    current =
      case token do
        {revision, id, _, _, _} when revision == cache.source_revision and is_reference(id) ->
          case lookup(cache.slots, id) do
            nil -> nil
            slot -> slot(slot, :entry)
          end

        _ ->
          nil
      end

    if current != nil and current.copy_receipt == entry.copy_receipt do
      {:ok, {:already_published, 0, 0, nil}}
    else
      refs = receipts(entry)

      with :ok <- effect_capacity(bounds, length(refs)),
           do: {:ok, {:stale_publish, 0, 0, refs}}
    end
  end

  defp valid_entry(
         %{
           source_revision: revision,
           lexical_key: _,
           analysis: %Analysis{
             limits: limits,
             budget: %Budget{scratch: 0},
             allocation: %{seed: %Budget{scratch: 0}, retained: allocation_bytes, counts: counts}
           },
           root_ownership: ownership,
           retained_receipts: retained,
           backing_receipts: backing,
           copy_receipt: copy
         } = entry
       )
       when map_size(entry) == 7 and is_reference(revision) and is_reference(copy) and
              ownership in [:borrowed, :retained] and is_map(limits) and map_size(limits) == 11 and
              is_integer(allocation_bytes) and allocation_bytes >= 0 and is_map(counts) and
              map_size(counts) == 4 do
    if receipt_list?(retained, 4) and receipt_list?(backing, 4) and
         Enum.all?([:facts, :regions, :occurrences, :edits], fn name ->
           is_integer(counts[name]) and counts[name] >= 0
         end) and
         Enum.all?(@limits, fn name ->
           n = limits[name]
           is_integer(n) and (n > 0 or (name == :max_bytes and n == 0))
         end),
       do: :ok,
       else: {:error, :invalid_entry}
  end

  defp valid_entry(_), do: {:error, :invalid_entry}
  defp receipt_list?([], _), do: true

  defp receipt_list?([ref | tail], n) when is_reference(ref) and n > 0,
    do: receipt_list?(tail, n - 1)

  defp receipt_list?(_, _), do: false
  defp receipts(nil), do: []

  defp receipts(entry),
    do: Enum.uniq([entry.copy_receipt | entry.retained_receipts ++ entry.backing_receipts])

  defp token_slot(cache, {revision, id, target, lease, attempt} = token)
       when revision == cache.source_revision and is_reference(id) and is_reference(target) and
              is_reference(lease) and
              is_reference(attempt) do
    case lookup(cache.slots, id) do
      slot when is_tuple(slot) ->
        if slot(slot, :token) === token and cache.status == :live,
          do: {:ok, slot},
          else: {:error, :stale_token}

      _ ->
        {:error, :stale_token}
    end
  end

  defp token_slot(_, _), do: {:error, :stale_token}

  defp execute(cache, {:acquire, key, target, lease, attempt}, {:compute, cost, _, key_bytes}, _) do
    token = {cache.source_revision, attempt, target, lease, attempt}
    slot = slot(id: attempt, key: key, key_bytes: key_bytes, token: token)

    cache = %{
      cache
      | keys: put(cache.keys, key, attempt),
        slots: put(cache.slots, attempt, slot),
        metadata_bytes: cache.metadata_bytes + cost
    }

    {{:compute, token}, add_owner(cache, {target, lease}, attempt, :producer), [], 1}
  end

  defp execute(cache, {:acquire, _, target, lease, attempt}, {:wait, cost, _, slot}, _) do
    id = slot(slot, :id)
    waiter = {:waiter, attempt, id, target, lease}
    slot = slot(slot, waiters: put(slot(slot, :waiters), attempt, true))

    cache = %{
      cache
      | waiters: put(cache.waiters, attempt, waiter),
        slots: put(cache.slots, id, slot),
        metadata_bytes: cache.metadata_bytes + cost
    }

    {{:waiting, attempt}, add_owner(cache, {target, lease}, id, {:waiter, attempt}), [], 1}
  end

  defp execute(cache, {:acquire, _, _, _, _}, {:candidate, _, _, entry}, _),
    do: {{:candidate, entry}, cache, [], 1}

  defp execute(cache, {:publish, {_rev, id, target, lease, _}, entry}, {:publish, _, _, slot}, _) do
    cache = remove_owner(cache, {target, lease}, id)
    slot = slot |> slot(status: :ready) |> slot(token: nil) |> slot(entry: entry)
    cache = %{cache | slots: put(cache.slots, id, slot)}
    cache = if size(slot(slot, :waiters)) > 0, do: enqueue(cache, id), else: cache
    {:published, cache, [], 1}
  end

  defp execute(cache, {:publish, _, _}, {:stale_publish, _, _, refs}, _),
    do: {{:error, :stale_token}, cache, Enum.map(refs, &{:release, &1}), 1}

  defp execute(cache, {:publish, _, _}, {:already_published, _, _, _}, _),
    do: {{:error, :already_published}, cache, [], 1}

  defp execute(cache, {:evict, _}, {:absent, _, _, _}, _), do: {:ok, cache, [], 1}

  defp execute(cache, {:evict, _}, {:evict, _, _, slot}, _) do
    {cache, effects} = retire_slot(cache, slot)
    {:ok, cache, effects, 1}
  end

  defp execute(cache, {:cancel, target, lease}, _, bounds),
    do: cancel_batch(cache, {:owner, {target, lease}}, bounds.max_visits, 0)

  defp execute(cache, {:owner_down, lease}, _, bounds),
    do: cancel_batch(cache, {:lease, lease}, bounds.max_visits, 0)

  defp execute(cache, :retire, _, bounds),
    do: drain(%{cache | status: :retiring}, bounds.max_visits, bounds.max_effects, [], 0)

  defp execute(cache, {:drain, n}, _, bounds),
    do: drain(cache, n, bounds.max_effects, [], 0)

  defp add_owner(cache, {_target, lease} = owner, id, role) do
    old = lookup(cache.requests, owner)
    ring = put(old || empty(), id, role)
    cache = %{cache | requests: put(cache.requests, owner, ring)}

    if old == nil do
      owners = put(lookup(cache.leases, lease) || empty(), owner, true)
      %{cache | leases: put(cache.leases, lease, owners)}
    else
      cache
    end
  end

  defp remove_owner(cache, {_target, lease} = owner, id) do
    ring = delete(get(cache.requests, owner), id)

    if size(ring) == 0 do
      owners = delete(get(cache.leases, lease), owner)

      %{
        cache
        | requests: delete(cache.requests, owner),
          leases:
            if(size(owners) == 0,
              do: delete(cache.leases, lease),
              else: put(cache.leases, lease, owners)
            )
      }
    else
      %{cache | requests: put(cache.requests, owner, ring)}
    end
  end

  defp request(cache, owner), do: lookup(cache.requests, owner) || empty()

  defp cancel_batch(cache, selection, 0, visited),
    do: batch_result(cache, selected_owner(cache, selection) == nil, [], visited)

  defp cancel_batch(cache, selection, left, visited) do
    case selected_owner(cache, selection) do
      nil ->
        batch_result(cache, true, [], visited)

      owner ->
        {id, role} = :gb_trees.smallest(get(cache.requests, owner))
        cache = remove_owner(cache, owner, id)

        cache =
          case role do
            :producer ->
              slot = get(cache.slots, id) |> slot(status: :draining) |> slot(token: nil)
              enqueue(%{cache | slots: put(cache.slots, id, slot)}, id)

            {:waiter, waiter} ->
              drop_waiter(cache, waiter, false)
          end

        cancel_batch(cache, selection, left - 1, visited + 1)
    end
  end

  defp selected_owner(cache, {:owner, owner}),
    do: if(lookup(cache.requests, owner) == nil, do: nil, else: owner)

  defp selected_owner(cache, {:lease, lease}) do
    case lookup(cache.leases, lease) do
      nil -> nil
      ring -> elem(:gb_trees.smallest(ring), 0)
    end
  end

  defp enqueue(cache, id) do
    slot = get(cache.slots, id)

    if slot(slot, :queued) do
      cache
    else
      slot = slot |> slot(previous: cache.tail) |> slot(following: nil) |> slot(queued: true)

      cache =
        if cache.tail do
          tail = get(cache.slots, cache.tail) |> slot(following: id)
          %{cache | slots: put(cache.slots, cache.tail, tail)}
        else
          %{cache | head: id}
        end

      %{cache | tail: id, slots: put(cache.slots, id, slot)}
    end
  end

  defp dequeue(cache, id) do
    slot = get(cache.slots, id)

    if slot(slot, :queued) do
      previous = slot(slot, :previous)
      following = slot(slot, :following)

      cache =
        if previous do
          value = get(cache.slots, previous) |> slot(following: following)
          %{cache | slots: put(cache.slots, previous, value)}
        else
          %{cache | head: following}
        end

      cache =
        if following do
          value = get(cache.slots, following) |> slot(previous: previous)
          %{cache | slots: put(cache.slots, following, value)}
        else
          %{cache | tail: previous}
        end

      slot = slot |> slot(previous: nil) |> slot(following: nil) |> slot(queued: false)
      %{cache | slots: put(cache.slots, id, slot)}
    else
      cache
    end
  end

  defp retire_slot(cache, slot) do
    id = slot(slot, :id)
    token = slot(slot, :token)

    cache =
      if token do
        {_, _, target, lease, _} = token
        remove_owner(cache, {target, lease}, id)
      else
        cache
      end

    effects = Enum.map(receipts(slot(slot, :entry)), &{:release, &1})
    slot = slot |> slot(status: :draining) |> slot(token: nil) |> slot(entry: nil)
    cache = %{cache | slots: put(cache.slots, id, slot)}

    cache =
      if size(slot(slot, :waiters)) == 0, do: delete_slot(cache, id), else: enqueue(cache, id)

    {cache, effects}
  end

  defp delete_slot(cache, id) do
    cache = dequeue(cache, id)
    slot = get(cache.slots, id)

    %{
      cache
      | slots: delete(cache.slots, id),
        keys: delete(cache.keys, slot(slot, :key)),
        metadata_bytes: cache.metadata_bytes - @obligation_bytes - 2 * slot(slot, :key_bytes)
    }
  end

  defp drop_waiter(cache, id, owner? \\ true) do
    {:waiter, _, slot_id, target, lease} = get(cache.waiters, id)
    cache = if owner?, do: remove_owner(cache, {target, lease}, slot_id), else: cache
    slot = get(cache.slots, slot_id)
    slot = slot(slot, waiters: delete(slot(slot, :waiters), id))

    %{
      cache
      | slots: put(cache.slots, slot_id, slot),
        waiters: delete(cache.waiters, id),
        metadata_bytes: cache.metadata_bytes - @obligation_bytes
    }
  end

  defp drain(cache, 0, _available, effects, visited),
    do: batch_result(cache, drain_done?(cache), Enum.reverse(effects), visited)

  defp drain(cache, left, available, effects, visited) do
    cond do
      cache.head != nil ->
        drain_slot(cache, get(cache.slots, cache.head), left, available, effects, visited)

      cache.status == :retiring and size(cache.slots) > 0 ->
        {_id, slot} = :gb_trees.smallest(cache.slots)
        need = length(receipts(slot(slot, :entry)))

        if need <= available do
          {cache, released} = retire_slot(cache, slot)
          drain(cache, left - 1, available - need, Enum.reverse(released, effects), visited + 1)
        else
          batch_result(cache, false, Enum.reverse(effects), visited)
        end

      true ->
        batch_result(cache, true, Enum.reverse(effects), visited)
    end
  end

  defp drain_slot(cache, slot, left, available, effects, visited) do
    cond do
      size(slot(slot, :waiters)) == 0 ->
        cache = finish_slot(cache, slot)
        drain(cache, left - 1, available, effects, visited + 1)

      available == 0 ->
        batch_result(cache, false, Enum.reverse(effects), visited)

      true ->
        {id, _} = :gb_trees.smallest(slot(slot, :waiters))
        {:waiter, _, _, target, lease} = get(cache.waiters, id)

        reason =
          cond do
            cache.status == :retiring -> :retired
            slot(slot, :status) == :ready -> :ready
            true -> :retry
          end

        cache = drop_waiter(cache, id)

        cache =
          if size(slot(get(cache.slots, slot(slot, :id)), :waiters)) == 0,
            do: finish_slot(cache, get(cache.slots, slot(slot, :id))),
            else: cache

        drain(
          cache,
          left - 1,
          available - 1,
          [{:wake, target, lease, reason} | effects],
          visited + 1
        )
    end
  end

  defp finish_slot(cache, slot) do
    if slot(slot, :entry) == nil,
      do: delete_slot(cache, slot(slot, :id)),
      else: dequeue(cache, slot(slot, :id))
  end

  defp drain_done?(cache),
    do: cache.head == nil and (cache.status == :live or size(cache.slots) == 0)

  defp batch_result(cache, done?, effects, visited),
    do: {{if(done?, do: :done, else: :more), visited}, cache, effects, visited}

  defp empty, do: :gb_trees.empty()
  defp size(tree), do: :gb_trees.size(tree)
  defp get(tree, key), do: :gb_trees.get(key, tree)

  defp lookup(tree, key) do
    case :gb_trees.lookup(key, tree) do
      :none -> nil
      {:value, value} -> value
    end
  end

  defp put(tree, key, value) do
    if :gb_trees.is_defined(key, tree),
      do: :gb_trees.update(key, value, tree),
      else: :gb_trees.insert(key, value, tree)
  end

  defp delete(tree, key), do: :gb_trees.delete(key, tree)
end
