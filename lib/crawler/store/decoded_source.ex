defmodule Crawler.Store.DecodedSource do
  @moduledoc """
  Pure custody of one physical decoded source. Candidates are borrowed, host-local
  values, never authority to send or adopt a body or its decoder checkpoint.

  The host prepays the COMPLETE immutable capsule copy and backing, retains live
  current-holder receipts before transfer, and checks current eleven limits and
  the complete original decoder floor before reuse. Receipt capacity is not a
  decoder certificate. This module never resets or reconstructs a Budget.

  `caps.pending` bounds waiters only. One producer is included in fixed root cost.
  `caps.context_bytes` is an explicit host metadata bound, with no default.
  Both are positive integers at most 134217727. Metadata is 4096 root bytes plus
  complete measured context bytes, plus 1024 per waiter. Payload funding is
  separate; the capsule pointer is retained exactly once without copying it.

  Each quote needs funded workspace BEFORE walking/comparing supplied context.
  Context workspace is 201216: 65536 continuation bytes, 512*(256+1) bounded
  pending/native frames, and 4096 fixed call/result bytes. A structural safety
  walk rejects functions before Retained can materialize an unbounded environment
  list, returning {:limit, :decoded_source_context_term}. This internal resource
  boundary does not validate header semantics or transform supported nested terms.
  Both walks cap depth/work and run
  separately. Complete real Retained measurement precedes exact comparison.

  For H=min(current waiters+growth,2*bits(pending cap)+2), structural workspace is
  4096+256*A+1024*L+256*E+256*R. Insert plus tail update uses A=2H+1,L=2,R=n+1;
  removal plus neighbour updates uses A=4H+1,L=2,R=0. Other commands have no
  native-node or waiter-record allocations. E<=1. Context and structural phases
  use their maximum, never a whole-cache/key/payload copy. OTP nodes are 40 bytes;
  256/node includes stack, rebalance borrowed pairs/list cells and node overlap.
  Rebalance uses current n+1, never future capacity. Cleanup needs no context
  walk, insertion or new retained credit. The host keeps cleanup_workspace/1
  prepaid separately and defers refunds/releases until obsolete frames end.

  A waiter record plus native node is at most 96 structural bytes and six
  conservatively charged 64-byte references, below 1024. Fixed root structures
  are at most 1024 bytes plus 32 such references and nine receipt-list cells,
  below 4096. All index keys/links are scalar references, not contexts or URLs.

  `requirements*` only quotes; numeric prepaid fields are host assertions, not
  Resources proofs. Refusals preserve exact state and produce no effects/debit.
  Stale/rejected incoming capsules remain host-owned, with no release effects.
  Publication accepts once; later publication returns :already_published.
  Recorded producer/waiter lease conflicts are rejected. The host retains the
  canonical execution binding after an obligation leaves this helper.
  """

  alias Crawler.Analysis.Budget
  alias Crawler.Store.Retained
  require Record

  Record.defrecordp(:waiter, [:lease, :target, :attempt, :previous, :following])

  @root_bytes 4096
  @waiter_bytes 1024
  @context_workspace 201_216
  @max_count 134_217_727
  @max_bytes 1_125_899_906_842_623
  @limit_keys [
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

  @enforce_keys [
    :source_revision,
    :decode_context,
    :context_bytes,
    :caps,
    :waiters,
    :metadata_bytes
  ]
  defstruct [
    :source_revision,
    :decode_context,
    :context_bytes,
    :caps,
    :waiters,
    :metadata_bytes,
    :producer,
    :published_token,
    :head,
    :tail,
    :wake_reason,
    :capsule,
    status: :vacant,
    releases: []
  ]

  @type caps :: %{pending: pos_integer(), context_bytes: pos_integer()}
  @type bounds :: %{max_visits: 0 | 1, max_effects: 0 | 1}
  @type prepaid :: %{retained_bytes: non_neg_integer(), workspace_bytes: non_neg_integer()}
  @type context :: %{content_type: binary() | nil, headers: list() | nil}
  @type token :: {reference(), reference(), reference(), reference()}
  @type capsule :: %{
          source_revision: reference(),
          decode_context: context(),
          body: binary(),
          decoder_seed: Budget.t(),
          limits: map(),
          unavailable: non_neg_integer(),
          root_ownership: :borrowed | :retained,
          retained_receipts: [reference()],
          backing_receipts: [reference()],
          copy_receipt: reference()
        }
  @type command ::
          {:acquire, context(), reference(), reference(), reference()}
          | {:publish, token(), capsule()}
          | {:owner_down, reference()}
          | :retire
          | :drain
  @type t :: %__MODULE__{}

  @doc "Workspace for one bounded context measurement call, held until that call unwinds."
  @spec context_workspace() :: 201_216
  def context_workspace, do: @context_workspace

  def maximum_context_bytes, do: @max_count

  @doc """
  Measures the COMPLETE exact context without constructing a root or token.
  Funding is checked before limit validation or context traversal. The explicit
  positive limit must be <=134217727. Unsupported nested functions return
  {:limit, :decoded_source_context_term}; no headers are transformed. This call
  does not retain context or grant transport credit. The host releases its
  measurement workspace only after this separate call frame has unwound.
  """
  @spec context_bytes(context(), pos_integer(), prepaid()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def context_bytes(context, limit, prepaid) do
    with :ok <- funded(prepaid, 0, context_workspace()),
         :ok <- valid_context_limit(limit),
         do: measure_context(context, limit)
  end

  @spec requirements_new(reference(), context(), caps(), prepaid()) ::
          {:ok, map()} | {:error, term()}
  def requirements_new(source, context, caps, prepaid) do
    with :ok <- valid_caps(caps),
         true <- is_reference(source) || {:error, :invalid_source_revision},
         {:ok, bytes} <- context_bytes(context, caps.context_bytes, prepaid) do
      {:ok, %{retained_bytes: @root_bytes + bytes, workspace_bytes: @context_workspace}}
    end
  end

  def new(source, context, caps, prepaid) do
    with {:ok, need} <- requirements_new(source, context, caps, prepaid),
         :ok <- funded(prepaid, need.retained_bytes, need.workspace_bytes) do
      {:ok,
       %__MODULE__{
         source_revision: source,
         decode_context: context,
         context_bytes: need.retained_bytes - @root_bytes,
         caps: caps,
         waiters: :gb_trees.empty(),
         metadata_bytes: need.retained_bytes
       }}
    end
  end

  @spec requirements(t(), command(), bounds(), prepaid()) :: {:ok, map()} | {:error, term()}
  def requirements(root, command, bounds, prepaid) do
    with {:ok, action} <- prepare(root, command, bounds, prepaid),
         do: {:ok, price(root, command, action)}
  end

  @spec transition(t(), command(), bounds(), prepaid()) :: {term(), t(), list(), map()}
  def transition(root, command, bounds, prepaid) do
    with {:ok, action} <- prepare(root, command, bounds, prepaid),
         need = price(root, command, action),
         :ok <- funded(prepaid, need.retained_bytes, need.workspace_bytes) do
      {result, next, effects} = apply_action(root, action)

      {result, next, effects,
       %{
         visited: need.max_visits,
         effects: length(effects),
         metadata_delta: next.metadata_bytes - root.metadata_bytes
       }}
    else
      {:error, reason} ->
        {{:error, reason}, root, [], %{visited: 0, effects: 0, metadata_delta: 0}}
    end
  end

  @spec cleanup_workspace(t()) :: non_neg_integer()
  def cleanup_workspace(%__MODULE__{caps: caps}), do: cleanup_workspace_for_caps(caps)

  @doc "Quotes the cleanup reserve before the host funds and constructs a root."
  @spec cleanup_workspace_for_caps(caps()) :: non_neg_integer()
  def cleanup_workspace_for_caps(caps) do
    structural(2 * bits(caps.pending) + 2, :remove, 1, 0)
  end

  defp valid_caps(%{pending: n, context_bytes: c} = caps)
       when map_size(caps) == 2 and is_integer(n) and n > 0 and n <= @max_count and
              is_integer(c) and c > 0 and c <= @max_count,
       do: :ok

  defp valid_caps(_), do: {:error, :invalid_caps}

  defp valid_bounds(%{max_visits: v, max_effects: e} = bounds)
       when map_size(bounds) == 2 and v in [0, 1] and e in [0, 1],
       do: :ok

  defp valid_bounds(_), do: {:error, :invalid_bounds}

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

  defp prepare(root, command, bounds, prepaid) do
    with :ok <- valid_bounds(bounds),
         :ok <- funded(prepaid, 0, preflight_workspace(root, command)),
         {:ok, action} <- plan(root, command, prepaid),
         {visits, effects} = action_bounds(action),
         true <- visits <= bounds.max_visits || {:error, :visit_capacity},
         true <- effects <= bounds.max_effects || {:error, :effect_capacity},
         do: {:ok, action}
  end

  defp bits(0), do: 0
  defp bits(n), do: 1 + bits(div(n, 2))
  defp count(root), do: :gb_trees.size(root.waiters)

  defp height(root, growth),
    do: min(count(root) + growth, 2 * bits(root.caps.pending) + 2)

  defp context_command?({:acquire, _, _, _, _}), do: true
  defp context_command?({:publish, _, _}), do: true
  defp context_command?(_), do: false

  defp preflight_workspace(root, command) do
    max(
      @root_bytes + 256 * height(root, 0),
      if(context_command?(command), do: @context_workspace, else: 0)
    )
  end

  defp structural(h, kind, effects, rebalance) do
    {nodes, records} =
      case kind do
        :insert -> {2 * h + 1, 2}
        :remove -> {4 * h + 1, 2}
        _ -> {0, 0}
      end

    @root_bytes + 256 * nodes + @waiter_bytes * records + 256 * effects + 256 * rebalance
  end

  defp price(root, command, action) do
    {visits, effects} = action_bounds(action)

    {kind, delta, rebalance} =
      case action do
        {:wait, _} -> {:insert, @waiter_bytes, count(root) + 1}
        {:remove, _} -> {:remove, -@waiter_bytes, 0}
        {:wake, _} -> {:remove, -@waiter_bytes, 0}
        _ -> {:fixed, 0, 0}
      end

    h = height(root, if(delta > 0, do: 1, else: 0))

    %{
      retained_bytes: max(delta, 0),
      workspace_bytes:
        max(preflight_workspace(root, command), structural(h, kind, effects, rebalance)),
      metadata_delta: delta,
      max_visits: visits,
      max_effects: effects,
      context_walk_steps_upper:
        if(context_command?(command), do: 1_000_010 + 4 * root.caps.context_bytes, else: 0),
      index_visits_upper: 16 * h + 8 * rebalance + 16
    }
  end

  defp action_bounds({:wake, _}), do: {1, 1}
  defp action_bounds({:release, _}), do: {1, 1}

  defp action_bounds({name, _}) when name in [:decode, :wait, :publish, :remove, :revoke],
    do: {1, 0}

  defp action_bounds(_), do: {0, 0}

  defp plan(root, {:acquire, context, target, lease, attempt}, prepaid)
       when is_reference(target) and is_reference(lease) and is_reference(attempt) do
    with :ok <- compatible(root, context, prepaid) do
      cond do
        root.status == :retiring ->
          {:error, :stale_source}

        root.producer != nil and elem(root.producer, 2) == lease ->
          if root.producer === {root.source_revision, target, lease, attempt},
            do: {:ok, {:same_decode, root.producer}},
            else: {:error, :conflicting_lease}

        true ->
          acquire_waiter(root, target, lease, attempt)
      end
    end
  end

  defp plan(root, {:publish, token, capsule}, prepaid) do
    cond do
      root.status == :retiring ->
        {:error, :stale_source}

      root.status == :ready ->
        {:error, :already_published}

      not valid_token?(token) or token !== root.producer ->
        {:error, :stale_producer}

      true ->
        with :ok <- capsule_shape(capsule),
             :ok <- compatible(root, capsule.decode_context, prepaid),
             true <- capsule.source_revision === root.source_revision || {:error, :stale_source},
             do: {:ok, {:publish, capsule}}
    end
  end

  defp plan(root, {:owner_down, lease}, _prepaid) when is_reference(lease) do
    cond do
      root.producer != nil and elem(root.producer, 2) == lease ->
        {:ok, {:revoke, nil}}

      true ->
        case lookup(root.waiters, lease) do
          nil -> {:ok, {:forget, lease}}
          record -> {:ok, {:remove, record}}
        end
    end
  end

  defp plan(%{status: :retiring}, :retire, _prepaid), do: {:ok, {:noop, :ok}}
  defp plan(root, :retire, _prepaid), do: {:ok, {:retire, receipts(root.capsule)}}

  defp plan(root, :drain, _prepaid) do
    cond do
      root.wake_reason != nil and root.head != nil -> {:ok, {:wake, get(root.waiters, root.head)}}
      root.releases != [] -> {:ok, {:release, hd(root.releases)}}
      true -> {:ok, {:noop, {:done, 0}}}
    end
  end

  defp plan(_, _, _), do: {:error, :invalid_command}

  defp acquire_waiter(root, target, lease, attempt) do
    record = lookup(root.waiters, lease)

    cond do
      record != nil and
          (waiter(record, :target) !== target or waiter(record, :attempt) !== attempt) ->
        {:error, :conflicting_lease}

      root.published_token != nil and elem(root.published_token, 2) == lease and
          root.published_token !== {root.source_revision, target, lease, attempt} ->
        {:error, :conflicting_lease}

      root.status == :ready ->
        {:ok, {:candidate, root.capsule}}

      record != nil ->
        {:ok, {:same_wait, attempt}}

      root.status == :vacant and root.head == nil ->
        {:ok, {:decode, {root.source_revision, target, lease, attempt}}}

      root.status == :vacant ->
        {:error, :source_busy}

      count(root) >= root.caps.pending ->
        {:error, {:limit, :decoded_source_waiters}}

      true ->
        {:ok, {:wait, {target, lease, attempt}}}
    end
  end

  defp valid_token?({source, target, lease, attempt}),
    do:
      is_reference(source) and is_reference(target) and is_reference(lease) and
        is_reference(attempt)

  defp valid_token?(_), do: false

  defp compatible(root, context, prepaid) do
    with {:ok, _bytes} <- context_bytes(context, root.caps.context_bytes, prepaid),
         true <- context === root.decode_context || {:error, :incompatible_decode_context},
         do: :ok
  end

  defp valid_context_limit(limit) when is_integer(limit) and limit > 0 and limit <= @max_count,
    do: :ok

  defp valid_context_limit(_), do: {:error, :invalid_context_limit}

  defp measure_context(%{content_type: type, headers: headers} = context, limit)
       when map_size(context) == 2 and (is_binary(type) or is_nil(type)) and
              (is_list(headers) or is_nil(headers)) do
    with :ok <- safe_terms([{context, 0}], 0, 0),
         {:ok, bytes} <- Retained.bytes(context, limit),
         true <- is_nil(headers) or proper_list?(headers) || {:error, :invalid_decode_context},
         do: {:ok, bytes}
  end

  defp measure_context(_, _), do: {:error, :invalid_decode_context}
  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false

  defp safe_terms(_, work, _) when work > 100_000, do: {:error, {:limit, :max_retained_bytes}}
  defp safe_terms([], _, _), do: :ok

  defp safe_terms([{_, depth} | _], _, _) when depth > 256,
    do: {:error, {:limit, :max_retained_bytes}}

  defp safe_terms([{:tuple, _, 0, _} | rest], work, space),
    do: safe_terms(rest, work, space - 256)

  defp safe_terms([{:tuple, term, index, depth} | rest], work, space),
    do:
      safe_terms(
        [{elem(term, index - 1), depth + 1}, {:tuple, term, index - 1, depth} | rest],
        work + 1,
        space
      )

  defp safe_terms([{:map, iterator, depth, cost} | rest], work, space) do
    case :maps.next(iterator) do
      :none ->
        safe_terms(rest, work, space - cost)

      {key, value, next} ->
        safe_terms(
          [{key, depth + 1}, {value, depth + 1}, {:map, next, depth, cost} | rest],
          work + 1,
          space
        )
    end
  end

  defp safe_terms([{term, depth} | rest], work, space) do
    cond do
      is_function(term) ->
        {:error, {:limit, :decoded_source_context_term}}

      is_list(term) and term != [] ->
        [head | tail] = term
        safe_terms([{head, depth + 1}, {tail, depth} | rest], work + 1, space)

      is_tuple(term) and space + 256 <= 65_536 ->
        safe_terms([{:tuple, term, tuple_size(term), depth} | rest], work, space + 256)

      is_map(term) and space + 512 + 128 * map_size(term) <= 65_536 ->
        cost = 512 + 128 * map_size(term)
        safe_terms([{:map, :maps.iterator(term), depth, cost} | rest], work, space + cost)

      is_tuple(term) or is_map(term) ->
        {:error, {:limit, :max_retained_bytes}}

      true ->
        safe_terms(rest, work + 1, space)
    end
  end

  defp capsule_shape(
         %{
           source_revision: source,
           decode_context: _,
           body: body,
           decoder_seed: %Budget{},
           limits: limits,
           unavailable: unavailable,
           root_ownership: ownership,
           retained_receipts: retained,
           backing_receipts: backing,
           copy_receipt: copy
         } = capsule
       )
       when map_size(capsule) == 10 and is_reference(source) and is_binary(body) and
              is_map(limits) and map_size(limits) == 11 and is_integer(unavailable) and
              unavailable >= 0 and ownership in [:borrowed, :retained] and is_reference(copy) do
    if Enum.all?(@limit_keys, &is_map_key(limits, &1)) and receipt_list?(retained, 0) and
         receipt_list?(backing, 0),
       do: :ok,
       else: {:error, :invalid_capsule}
  end

  defp capsule_shape(_), do: {:error, :invalid_capsule}
  defp receipt_list?([], _), do: true

  defp receipt_list?([ref | rest], n) when is_reference(ref) and n < 4,
    do: receipt_list?(rest, n + 1)

  defp receipt_list?(_, _), do: false
  defp receipts(nil), do: []

  defp receipts(capsule),
    do: Enum.uniq([capsule.copy_receipt | capsule.retained_receipts ++ capsule.backing_receipts])

  defp apply_action(root, {:same_decode, token}), do: {{:decode, token}, root, []}
  defp apply_action(root, {:same_wait, attempt}), do: {{:waiting, attempt}, root, []}
  defp apply_action(root, {:candidate, capsule}), do: {{:decoded, capsule}, root, []}
  defp apply_action(root, {:noop, result}), do: {result, root, []}

  defp apply_action(root, {:decode, token}),
    do: {{:decode, token}, %{root | status: :decoding, producer: token}, []}

  defp apply_action(root, {:wait, {target, lease, attempt}}) do
    record =
      waiter(lease: lease, target: target, attempt: attempt, previous: root.tail, following: nil)

    tree =
      if root.tail == nil,
        do: root.waiters,
        else:
          :gb_trees.update(
            root.tail,
            waiter(get(root.waiters, root.tail), following: lease),
            root.waiters
          )

    tree = :gb_trees.insert(lease, record, tree)

    next = %{
      root
      | waiters: tree,
        head: root.head || lease,
        tail: lease,
        metadata_bytes: root.metadata_bytes + @waiter_bytes
    }

    {{:waiting, attempt}, next, []}
  end

  defp apply_action(root, {:publish, capsule}),
    do:
      {:ok,
       %{
         root
         | status: :ready,
           capsule: capsule,
           published_token: root.producer,
           producer: nil,
           wake_reason: if(root.head == nil, do: nil, else: :ready)
       }, []}

  defp apply_action(root, {:revoke, _}),
    do:
      {:ok,
       %{
         root
         | status: :vacant,
           producer: nil,
           wake_reason: if(root.head == nil, do: nil, else: :retry)
       }, []}

  defp apply_action(root, {:forget, lease}) do
    if root.published_token != nil and elem(root.published_token, 2) == lease,
      do: {:ok, %{root | published_token: nil}, []},
      else: {:ok, root, []}
  end

  defp apply_action(root, {:remove, record}), do: {:ok, remove(root, record), []}

  defp apply_action(root, {:retire, releases}),
    do:
      {:ok,
       %{
         root
         | status: :retiring,
           producer: nil,
           published_token: nil,
           capsule: nil,
           releases: releases,
           wake_reason: if(root.head == nil, do: nil, else: :retired)
       }, []}

  defp apply_action(root, {:wake, record}) do
    reason = root.wake_reason
    next = remove(root, record)

    {drain_result(next), next,
     [{:wake, root.source_revision, waiter(record, :target), waiter(record, :lease), reason}]}
  end

  defp apply_action(root, {:release, receipt}) do
    next = %{root | releases: tl(root.releases)}
    {drain_result(next), next, [{:release, receipt}]}
  end

  defp remove(root, record) do
    previous = waiter(record, :previous)
    following = waiter(record, :following)
    tree = root.waiters

    tree =
      if previous == nil,
        do: tree,
        else: :gb_trees.update(previous, waiter(get(tree, previous), following: following), tree)

    tree =
      if following == nil,
        do: tree,
        else: :gb_trees.update(following, waiter(get(tree, following), previous: previous), tree)

    tree = :gb_trees.delete(waiter(record, :lease), tree)
    head = if root.head == waiter(record, :lease), do: following, else: root.head
    tail = if root.tail == waiter(record, :lease), do: previous, else: root.tail

    %{
      root
      | waiters: tree,
        head: head,
        tail: tail,
        wake_reason: if(head == nil, do: nil, else: root.wake_reason),
        metadata_bytes: root.metadata_bytes - @waiter_bytes
    }
  end

  defp drain_result(root),
    do:
      {if((root.wake_reason != nil and root.head != nil) or root.releases != [],
         do: :more,
         else: :done
       ), 1}

  defp lookup(tree, key) do
    case :gb_trees.lookup(key, tree) do
      :none -> nil
      {:value, value} -> value
    end
  end

  defp get(tree, key), do: :gb_trees.get(key, tree)
end
