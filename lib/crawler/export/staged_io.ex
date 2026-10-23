defmodule Crawler.Export.StagedIO do
  @moduledoc """
  Bounded private staging operations. Call from a funded producer or IO worker.

  Plans contain descriptors and trusted budget capsules, never payloads. The
  owner must reserve Resources credit before sending any backing to a worker.
  `funding/4` validates that reservation against the real ledger. At use time,
  the worker checks the existing protected Authority grant and execution lease.
  Plans and funding tokens are trusted internal capabilities, not public input.
  The owner freezes receipt capacities while a Funding token is live. A receipt
  commit or role change requires a new token; Authority fences grants and leases,
  not capacity changes. Funding never claims a fresh ledger read at use time.

  Metadata is uncompressed ETF. Its expanded structural tariff is calculated
  before encoding, without assuming term sharing. Replay replaces the ended
  producer's retained allocation charge; it preserves counts, caps, and peak
  history. Encoded backing and the expanded replacement overlap in one prepaid
  reservation. These are conservative accounting tariffs, not VM heap measures.
  The owner must end the producer lifetime before using `replay/3`. A replay
  capsule needs fresh overlap credit, not the historical producer receipts.
  Retained credit pays existing structures, backing credit proves borrowed root
  bytes, and overlap credit pays incremental allocations; the roles never pool.
  Replay validates both collections, then drops the decoded original collection
  before render. Its immutable disk copy and trusted budget capsule remain.
  """

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Export.Filesystem
  alias Crawler.Export.Paths
  alias Crawler.Store.Authority
  alias Crawler.Store.Resources

  defmodule Plan do
    @moduledoc false
    @derive {Inspect, only: [:kind, :area, :path, :bytes]}
    @enforce_keys [:kind, :area, :path, :bytes, :digest]
    defstruct [
      :kind,
      :area,
      :path,
      :bytes,
      :digest,
      :source_revision,
      :source_digest,
      :analysis_revision,
      :css_revision,
      :analysis_budget,
      :original_budget,
      :bound_budget,
      :decoded_bytes,
      :read_capacity,
      :edges_digest,
      :unavailable,
      :root_ownership,
      :root_bytes
    ]
  end

  defmodule Funding do
    @moduledoc false
    @derive {Inspect, only: [:retained_capacity, :backing_capacity, :overlap_capacity]}
    @enforce_keys [
      :retained,
      :backing,
      :overlap,
      :grants,
      :lease,
      :holder,
      :arena,
      :run,
      :retained_capacity,
      :backing_capacity,
      :overlap_capacity,
      :unavailable
    ]
    defstruct @enforce_keys
  end

  defmodule Ack do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [:plan, :ticket]
    defstruct [:plan, :ticket, :operation]
  end

  def funding(
        ledger,
        %{retained: retained, backing: backing, overlap: overlap, unavailable: unavailable} =
          capsule,
        lease,
        holder
      )
      when is_list(retained) and is_list(backing) and is_reference(overlap) and
             is_integer(unavailable) and unavailable >= 0 and is_reference(lease) and
             is_pid(holder) and map_size(capsule) == 4 do
    with true <- bounded_refs?(retained, 4) and bounded_refs?(backing, 4),
         refs = retained ++ backing ++ [overlap],
         true <- length(Enum.uniq(refs)) == length(refs),
         {:ok, grants} <- grants(ledger, refs, lease, holder),
         [first | _] = Map.values(grants),
         true <-
           Enum.all?(grants, fn {_ref, grant} ->
             grant.arena == first.arena and grant.run == first.run
           end),
         funding = %Funding{
           retained: retained,
           backing: backing,
           overlap: overlap,
           grants: grants,
           lease: lease,
           holder: holder,
           arena: first.arena,
           run: first.run,
           retained_capacity: total(grants, retained),
           backing_capacity: total(grants, backing),
           overlap_capacity: grants[overlap].capacity,
           unavailable: unavailable
         },
         :ok <- current(funding) do
      {:ok, funding}
    else
      _ -> {:error, :unfunded}
    end
  end

  def funding(_ledger, _capsule, _lease, _holder), do: {:error, :unfunded}

  def credit_spec(%Funding{} = funding),
    do: Map.take(funding, [:retained, :backing, :overlap, :unavailable])

  defp bounded_refs?([], _remaining), do: true

  defp bounded_refs?([ref | rest], remaining) when remaining > 0 and is_reference(ref),
    do: bounded_refs?(rest, remaining - 1)

  defp bounded_refs?(_refs, _remaining), do: false

  defp grants(ledger, refs, lease, holder) do
    Enum.reduce_while(refs, {:ok, %{}}, fn ref, {:ok, found} ->
      with %{holders: holders} = record <- Resources.receipt(ledger, ref),
           %{status: status, lease: ^lease, arena: arena} <- holders[holder],
           true <- status in [:owned, :pending, :adopted, :retained],
           %{open?: true, lease: ^lease, run: run} <- ledger.arenas[arena],
           %{retired?: false} <- ledger.runs[run],
           capacity = record.actual || record.capacity,
           true <- is_integer(capacity) and capacity >= 0 do
        {:cont, {:ok, Map.put(found, ref, %{arena: arena, run: run, capacity: capacity})}}
      else
        _ -> {:halt, {:error, :unfunded}}
      end
    end)
  end

  defp total(grants, refs), do: Enum.reduce(refs, 0, &(&2 + grants[&1].capacity))

  defp current(%Funding{} = funding) do
    if Authority.execution_current?(funding.lease) and
         Enum.all?(funding.grants, fn {ref, grant} ->
           grant.arena == funding.arena and grant.run == funding.run and
             Authority.resource_current?(ref, funding.lease, funding.holder)
         end),
       do: :ok,
       else: {:error, :stale_resource}
  end

  @doc "Check incremental workspace only; borrowed backing never funds copies."
  def authorized(%Funding{holder: holder} = funding, bytes)
      when is_integer(bytes) and bytes >= 0 do
    with true <- holder == self() or {:error, :wrong_holder},
         :ok <- current(funding),
         true <- bytes <= funding.overlap_capacity or {:error, {:limit, :receipt_capacity}} do
      :ok
    end
  end

  defp producer_authorized(funding, plan) do
    with :ok <- authorized(funding, plan.bytes),
         true <- funding.unavailable == plan.unavailable or {:error, :funding_lineage_mismatch},
         true <- plan.bound_budget.retained >= plan.unavailable or {:error, :invalid_lineage},
         true <-
           funding.retained_capacity >= plan.bound_budget.retained - plan.unavailable or
             {:error, {:limit, :retained_capacity}},
         :ok <- root_authorized(funding, plan.root_ownership, plan.root_bytes) do
      :ok
    end
  end

  defp root_authorized(funding, :borrowed, bytes) do
    if funding.backing_capacity >= bytes,
      do: :ok,
      else: {:error, {:limit, :backing_capacity}}
  end

  defp root_authorized(funding, :retained, bytes) do
    if funding.retained_capacity >= bytes,
      do: :ok,
      else: {:error, {:limit, :retained_capacity}}
  end

  def plan_source(path, bytes, source_revision),
    do: plan_source(path, bytes, source_revision, :borrowed)

  def plan_source(path, bytes, source_revision, root_ownership)
      when is_binary(bytes) and is_reference(source_revision) and
             root_ownership in [:borrowed, :retained] do
    with {:ok, plan} <- plan_bytes(:archive, path, bytes) do
      {:ok,
       %{
         plan
         | kind: :source,
           area: :source,
           source_revision: source_revision,
           source_digest: plan.digest,
           root_ownership: root_ownership,
           root_bytes: :binary.referenced_byte_size(bytes)
       }}
    end
  end

  def plan_bytes(:archive, path, bytes) when is_binary(bytes) do
    if Paths.relative_file?(path) do
      digest = :crypto.hash(:sha256, bytes)

      {:ok,
       %Plan{
         kind: :archive,
         area: :archive,
         path: path,
         bytes: byte_size(bytes),
         digest: digest
       }}
    else
      {:error, :invalid_path}
    end
  end

  def plan_metadata(
        path,
        %Analysis{} = analysis,
        original,
        bound,
        css_revision,
        source_revision,
        %{unavailable: unavailable, root: root_ownership} = lineage
      )
      when is_reference(source_revision) and is_integer(unavailable) and unavailable >= 0 and
             root_ownership in [:borrowed, :retained] and map_size(lineage) == 2 do
    with true <- Paths.relative_file?(path) or {:error, :invalid_path},
         {:ok, _} <- Analysis.continuation_budget(analysis, original),
         {:ok, budget} <-
           Analysis.continuation_budget(%{analysis | budget: original.budget}, bound),
         true <-
           same_bindings?(original.occurrences, bound.occurrences) or
             {:error, :changed_occurrence_collection},
         true <- budget.retained >= unavailable or {:error, :invalid_lineage},
         true <-
           root_ownership != :retained or
             budget.retained - unavailable >= root_bytes(analysis) or {:error, :invalid_lineage},
         bundle = bundle(analysis, original, bound, css_revision, source_revision, lineage),
         {:ok, decoded_bytes} <- measure(bundle, budget.limit),
         bytes = :erlang.external_size(bundle),
         {:ok, _} <- Budget.reserve(budget, bytes),
         replacement = decoded_bytes + bytes,
         {:ok, empty} <- Budget.refund(budget, budget.retained - unavailable),
         {:ok, _} <- Budget.reserve(empty, replacement + 1) do
      {:ok,
       %Plan{
         kind: :metadata,
         area: :metadata,
         path: path,
         bytes: bytes,
         digest: nil,
         source_revision: source_revision,
         source_digest: source_digest(analysis),
         analysis_revision: analysis.revision,
         css_revision: css_revision,
         analysis_budget: analysis.budget,
         original_budget: original.budget,
         bound_budget: bound.budget,
         decoded_bytes: decoded_bytes,
         read_capacity: replacement,
         edges_digest: edge_digest(bound.occurrences),
         unavailable: unavailable,
         root_ownership: root_ownership,
         root_bytes: root_bytes(analysis)
       }}
    end
  end

  def plan_metadata(_path, _analysis, _original, _bound, _css, _source, _lineage),
    do: {:error, :invalid_lineage}

  def encode(%Plan{kind: :metadata} = plan, analysis, original, bound, funding) do
    with :ok <- producer_authorized(funding, plan),
         {:ok, expected} <-
           plan_metadata(
             plan.path,
             analysis,
             original,
             bound,
             plan.css_revision,
             plan.source_revision,
             %{unavailable: plan.unavailable, root: plan.root_ownership}
           ),
         true <- expected == plan or {:error, :plan_mismatch},
         {:ok, reserved} <- Budget.reserve(bound.budget, plan.bytes) do
      bytes =
        :erlang.term_to_binary(
          bundle(analysis, original, bound, plan.css_revision, plan.source_revision, %{
            unavailable: plan.unavailable,
            root: plan.root_ownership
          })
        )

      with true <- byte_size(bytes) == plan.bytes or {:error, :encoded_size_mismatch},
           {:ok, budget} <- Budget.settle(reserved, plan.bytes, plan.bytes) do
        {:ok, %{plan | digest: :crypto.hash(:sha256, bytes)}, bytes, budget}
      end
    end
  end

  def write(%Plan{} = plan, bytes, filesystem, funding) when is_binary(bytes) do
    with :ok <- write_authorized(funding, plan, bytes),
         true <- byte_size(bytes) == plan.bytes or {:error, :size_mismatch},
         true <- :crypto.hash(:sha256, bytes) == plan.digest or {:error, :digest_mismatch},
         {:ok, ticket} <- Filesystem.reserve(filesystem, plan.area, plan.path, plan.bytes),
         :ok <- write_authorized(funding, plan, bytes),
         :ok <- Filesystem.write(filesystem, ticket, bytes) do
      {:ok, %Ack{plan: plan, ticket: ticket}}
    end
  end

  defp write_authorized(funding, %Plan{kind: :source} = plan, bytes) do
    with :ok <- authorized(funding, 0),
         true <-
           plan.root_bytes == :binary.referenced_byte_size(bytes) or
             {:error, :root_backing_mismatch},
         :ok <- root_authorized(funding, plan.root_ownership, plan.root_bytes),
         do: :ok
  end

  defp write_authorized(funding, _plan, bytes),
    do: authorized(funding, :binary.referenced_byte_size(bytes))

  @doc "Validate an already receipt-funded Store delivery before touching its payload."
  def delivery(
        {:crawler_resource_delivery, receipt, lease, reply_to, delivery_ref, payload},
        %Funding{lease: lease} = funding
      )
      when is_pid(reply_to) and is_reference(delivery_ref) do
    with true <- Map.has_key?(funding.grants, receipt) or {:error, :invalid_delivery},
         :ok <- authorized(funding, 0) do
      {:ok, payload, {reply_to, delivery_ref}}
    end
  end

  def delivery(_message, _funding), do: {:error, :invalid_delivery}

  @doc "One IO-worker mailbox step. Settlement follows the actual filesystem reply."
  def perform_delivery(message, funding, filesystem, owner) when is_pid(owner) do
    result =
      case delivery(message, funding) do
        {:ok, payload, _reply} ->
          Enum.each(funding.grants, fn {ref, _} ->
            send(owner, {:crawler_resource_adopted, ref, self()})
          end)

          execute_payload(payload, filesystem, funding)

        error ->
          error
      end

    report_delivery(message, funding, owner, result)
  end

  defp execute_payload({:write, %Plan{} = plan, bytes}, filesystem, funding)
       when is_binary(bytes),
       do: write(plan, bytes, filesystem, funding)

  defp execute_payload(_payload, _filesystem, _funding), do: {:error, :invalid_io_payload}

  defp report_delivery(
         {:crawler_resource_delivery, receipt, lease, reply_to, ref, _payload},
         %Funding{lease: lease} = funding,
         owner,
         result
       ) do
    if Map.has_key?(funding.grants, receipt) do
      Enum.each(funding.grants, fn {grant, _} ->
        send(owner, {:crawler_resource_settled, grant, self(), :released})
      end)

      send(reply_to, {ref, result})
    end

    result
  end

  defp report_delivery(_message, _funding, _owner, result), do: result

  def read(%Plan{} = plan, receipt, funding) do
    with :ok <- authorized(funding, plan.bytes + 1),
         {:ok, bytes} <- read_exact(plan, receipt),
         :ok <- authorized(funding, plan.bytes + 1) do
      {:ok, bytes}
    end
  end

  def replay(%Plan{kind: :metadata} = plan, receipt, funding) do
    with :ok <- authorized(funding, plan.read_capacity + 1),
         true <- funding.unavailable == plan.unavailable or {:error, :funding_lineage_mismatch},
         {:ok, empty} <-
           Budget.refund(
             plan.bound_budget,
             plan.bound_budget.retained - plan.unavailable
           ),
         {:ok, reserved} <- Budget.reserve(empty, plan.read_capacity + 1),
         {:ok, bytes} <- read_exact(plan, receipt) do
      decode(plan, bytes, reserved, funding)
    end
  end

  def measure(term, limit) when is_integer(limit) and limit >= 0,
    do: walk(term, 0, 0, limit)

  def edge_digest(occurrences) do
    occurrences
    |> Enum.reduce(:crypto.hash_init(:sha256), fn occurrence, hash ->
      :crypto.hash_update(
        hash,
        :erlang.term_to_binary(
          {occurrence.id, occurrence.source_revision, occurrence.target, occurrence.url}
        )
      )
    end)
    |> :crypto.hash_final()
  end

  def compact_edges(occurrences),
    do: Enum.map(occurrences, &Map.take(&1, [:id, :source_revision, :target, :url]))

  defp decode(_plan, <<131, 80, _::binary>>, _reserved, _funding),
    do: {:error, :compressed_metadata}

  defp decode(plan, bytes, reserved, funding) do
    with :ok <- authorized(funding, plan.read_capacity + 1),
         {bundle, used} <- :erlang.binary_to_term(bytes, [:safe, :used]),
         true <- used == plan.bytes or {:error, :trailing_metadata},
         :ok <- capsules(plan, bundle),
         {:ok, measured} <- measure(bundle, plan.decoded_bytes),
         true <- measured == plan.decoded_bytes or {:error, :metadata_shape_mismatch},
         {:ok, budget} <- Budget.settle(reserved, plan.read_capacity + 1, plan.read_capacity),
         {:ok, original_bytes} <-
           measure(Map.delete(bundle.original, :budget), plan.decoded_bytes),
         {:ok, budget} <- Budget.refund(budget, original_bytes) do
      analysis = %{bundle.analysis | budget: %{budget | counts: plan.analysis_budget.counts}}
      bound = %{bundle.bound | budget: budget}

      with {:ok, _} <- Analysis.continuation_budget(analysis, bound),
           :ok <- authorized(funding, plan.read_capacity + 1) do
        {:ok,
         %{
           analysis: analysis,
           original_budget: plan.original_budget,
           bound: bound,
           css_revision: plan.css_revision,
           source_revision: plan.source_revision
         }}
      end
    else
      false -> {:error, :invalid_metadata}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :invalid_metadata}
  end

  defp capsules(plan, %{
         analysis: %Analysis{} = analysis,
         original: original,
         bound: bound,
         css_revision: css_revision,
         source_revision: source_revision,
         lineage: lineage
       }) do
    if analysis.revision == plan.analysis_revision and
         source_revision == plan.source_revision and
         source_digest(analysis) == plan.source_digest and
         css_revision == plan.css_revision and
         lineage == %{unavailable: plan.unavailable, root: plan.root_ownership} and
         byte_size(analysis.regions[analysis.root].source) <= plan.root_bytes and
         analysis.budget == plan.analysis_budget and
         original.budget == plan.original_budget and bound.budget == plan.bound_budget and
         original.source_revision == plan.analysis_revision and
         bound.source_revision == plan.analysis_revision and
         same_bindings?(original.occurrences, bound.occurrences),
       do: :ok,
       else: {:error, :metadata_capsule_mismatch}
  end

  defp capsules(_plan, _bundle), do: {:error, :metadata_capsule_mismatch}

  defp bundle(analysis, original, bound, revision, source_revision, lineage),
    do: %{
      analysis: analysis,
      original: original,
      bound: bound,
      css_revision: revision,
      source_revision: source_revision,
      lineage: lineage
    }

  defp root_bytes(analysis),
    do: :binary.referenced_byte_size(analysis.regions[analysis.root].source)

  defp source_digest(analysis),
    do: :crypto.hash(:sha256, analysis.regions[analysis.root].source)

  defp same_bindings?([], []), do: true

  defp same_bindings?([original | originals], [bound | bounds]),
    do:
      map_size(original) == map_size(bound) and
        same_occurrence?(:maps.iterator(original), bound) and same_bindings?(originals, bounds)

  defp same_bindings?(_original, _bound), do: false

  defp same_occurrence?(iterator, bound) do
    case :maps.next(iterator) do
      :none ->
        true

      {:target, _value, next} ->
        same_occurrence?(next, bound)

      {key, value, next} ->
        match?({:ok, ^value}, Map.fetch(bound, key)) and same_occurrence?(next, bound)
    end
  end

  defp read_exact(plan, receipt) do
    with true <- Paths.relative_file?(plan.path) or {:error, :invalid_path},
         true <- plan.area in [:source, :metadata, :archive] or {:error, :invalid_area},
         :ok <- unchanged_directory(receipt.root, receipt.root_id),
         :ok <- unchanged_directory(receipt.stage, receipt.stage_id),
         path = Path.join([receipt.stage, Atom.to_string(plan.area), plan.path]),
         :ok <- directories(Path.dirname(path), receipt.stage),
         {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size == plan.bytes or {:error, :size_mismatch} do
      case File.open(path, [:read, :binary, :raw], &read_bytes(&1, plan)) do
        {:ok, result} -> result
        error -> error
      end
    else
      {:ok, _} -> {:error, :unsafe_path}
      error -> error
    end
  end

  defp read_bytes(file, plan) do
    result =
      case IO.binread(file, plan.bytes + 1) do
        :eof when plan.bytes == 0 -> ""
        result -> result
      end

    case result do
      bytes when is_binary(bytes) and byte_size(bytes) == plan.bytes ->
        if :crypto.hash(:sha256, bytes) == plan.digest,
          do: {:ok, bytes},
          else: {:error, :digest_mismatch}

      _ ->
        {:error, :size_mismatch}
    end
  end

  defp directories(path, stop) when path == stop, do: :ok

  defp directories(path, stop) do
    with {:ok, %{type: :directory}} <- File.lstat(path),
         do: directories(Path.dirname(path), stop)
  end

  defp unchanged_directory(path, expected) do
    with {:ok, info} <- File.lstat(path),
         true <- {info.type, info.major_device, info.minor_device, info.inode} == expected do
      :ok
    else
      _ -> {:error, :ownership_changed}
    end
  end

  defp walk(_term, _depth, used, limit) when used > limit,
    do: {:error, {:limit, :analysis_bytes}}

  defp walk(_term, depth, _used, _limit) when depth > 256,
    do: {:error, {:limit, :analysis_depth}}

  defp walk(term, _depth, used, limit) when is_binary(term),
    do: add(used, 64 + byte_size(term), limit)

  defp walk([], _depth, used, limit), do: add(used, 8, limit)

  defp walk([head | tail], depth, used, limit) do
    with {:ok, used} <- add(used, 16, limit),
         {:ok, used} <- walk(head, depth + 1, used, limit),
         do: walk(tail, depth, used, limit)
  end

  defp walk(term, depth, used, limit) when is_map(term) do
    with {:ok, used} <- add(used, 64, limit),
         do: walk_map(:maps.iterator(term), depth, used, limit)
  end

  defp walk(term, depth, used, limit) when is_tuple(term) do
    with {:ok, used} <- add(used, 16 + 8 * tuple_size(term), limit),
         do: walk_tuple(term, 0, depth, used, limit)
  end

  defp walk(term, _depth, used, limit) when is_atom(term), do: add(used, 8, limit)

  defp walk(term, _depth, used, limit) when is_integer(term) or is_float(term),
    do: add(used, 16 + :erlang.external_size(term), limit)

  defp walk(term, _depth, used, limit) when is_reference(term),
    do: add(used, 64 + :erlang.external_size(term), limit)

  defp walk(_term, _depth, _used, _limit), do: {:error, :unsupported_metadata}

  defp walk_map(iterator, depth, used, limit) do
    case :maps.next(iterator) do
      :none ->
        {:ok, used}

      {key, value, next} ->
        with {:ok, used} <- add(used, 32, limit),
             {:ok, used} <- walk(key, depth + 1, used, limit),
             {:ok, used} <- walk(value, depth + 1, used, limit),
             do: walk_map(next, depth, used, limit)
    end
  end

  defp walk_tuple(term, index, _depth, used, _limit) when index == tuple_size(term),
    do: {:ok, used}

  defp walk_tuple(term, index, depth, used, limit) do
    with {:ok, used} <- walk(elem(term, index), depth + 1, used, limit),
         do: walk_tuple(term, index + 1, depth, used, limit)
  end

  defp add(used, bytes, limit) when used + bytes <= limit, do: {:ok, used + bytes}
  defp add(_used, _bytes, _limit), do: {:error, {:limit, :analysis_bytes}}
end
