defmodule Crawler.Analysis do
  @moduledoc """
  Immutable source facts shared by discovery and rendering.

  `analyze/2` accepts decoded source bytes. Call [`Crawler.Charset.decode/2`](https://github.com/fredwu/crawler/blob/master/lib/crawler/charset.ex#L11) at the
  response boundary first. `analyze/3` accepts the explicit continuing Budget from
  a managed decoder; converted root backing remains charged through later phases.
  Analysis does not acquire crawl authority or admit work.
  Interpretation uses a bounded pure document stylesheet context. Managed callers
  supply already-settled `css_tokens`, optional `css_references`, and `css_revision`
  to bypass local graph resolution. `max_total_bytes` bounds additional retained
  analysis values and overlapping scratch; the caller owns the root body backing.

  Managed callers keep `css_groups_result/2` and pass that collection to
  `occurrences_result/3`. Keep the returned occurrence collection through `bind/2`
  and rendering so the same allocation budget spans every phase. List convenience
  APIs remain available; rendering a supplied list charges a conservative structural
  adoption against the lexical budget. Caller options cannot replace this budget.

  Bind each occurrence to its admitted target with `Occurrence.bind/2`. A render
  resolver receives that occurrence and returns `{:local, path}`, `{:online, url}`,
  `:keep`, or `{:error, reason}`. Local results require a bound target handle.
  Discovery and export must retain the same occurrence collection.
  """

  alias Crawler.Analysis.Budget
  alias Crawler.Analysis.Interpretation
  alias Crawler.Analysis.Lexical
  alias Crawler.Analysis.Limits
  alias Crawler.Analysis.Occurrence
  alias Crawler.Analysis.Render
  alias Crawler.MediaType

  @enforce_keys [:root, :regions, :revision, :mode, :limits, :stats]
  defstruct [
    :root,
    :regions,
    :revision,
    :mode,
    :limits,
    :stats,
    :budget,
    :lexical_key,
    :allocation,
    source_options: %{}
  ]

  def analyze(source, opts \\ [])

  def analyze(source, opts) when is_binary(source) do
    opts = Map.new(opts)

    with {:ok, limits} <- Limits.new(opts),
         do: analyze_source(source, opts, limits, Budget.new(limits))
  end

  def analyze(_source, _opts), do: {:error, :invalid_source}

  def analyze(source, opts, seed) when is_binary(source) do
    opts = Map.new(opts)

    with {:ok, limits} <- Limits.new(opts),
         {:ok, budget} <- validate_budget(Budget.new(limits), seed),
         do: analyze_source(source, opts, limits, budget)
  end

  def analyze(_source, _opts, _seed), do: {:error, :invalid_source}

  defp analyze_source(source, opts, limits, seed) do
    with :ok <- Limits.check(byte_size(source), limits.max_bytes, :source_bytes),
         :ok <- valid_source(source, opts),
         {:ok, root, regions, stats, budget} <- Lexical.run(source, opts, limits, seed),
         {:ok, revision, budget} <-
           revision(source, lexical_options(regions[root].kind, opts), budget),
         {:ok, key, budget} <- lexical_key_result(opts, budget),
         {:ok, budget} <- Budget.charge(budget, Budget.cost(:context)) do
      {:ok,
       %__MODULE__{
         root: root,
         regions: regions,
         revision: revision,
         budget: budget,
         mode: regions[root].kind,
         limits: limits,
         stats: stats,
         lexical_key: key,
         allocation: allocation(seed, budget),
         source_options: source_options(opts)
       }}
    end
  end

  @doc "Returns the canonical source-mode key on the continuing allocation budget."
  def lexical_key_result(opts, %Budget{} = budget) do
    opts = Map.new(opts)
    headers = opts[:headers] || []
    type = opts[:content_type]
    hold = 512 + 256 * if(is_binary(type), do: byte_size(type), else: 0)

    with true <- is_list(headers) || {:error, :invalid_headers},
         :ok <- Limits.check(length(headers), budget.caps.facts, :headers),
         {:ok, budget} <- Budget.reserve(budget, hold) do
      kind = Lexical.kind(opts)

      if match?({:javascript, goal} when goal not in [:module, :script], kind) do
        {:error, :invalid_script_goal}
      else
        mode = if kind == :css, do: {:css, :stylesheet}, else: kind
        type = if MediaType.javascript?(type), do: :javascript, else: MediaType.normalize(type)
        bytes = if is_binary(type), do: byte_size(type) + Budget.cost(:binary), else: 0

        with {:ok, budget} <- Budget.charge(budget, Budget.cost(:context) + bytes),
             {:ok, budget} <- adopt(budget, headers),
             {:ok, budget} <- Budget.release(budget, hold),
             do: {:ok, {mode, type, headers}, budget}
      end
    end
  end

  def lexical_key_result(_opts, _budget), do: {:error, :invalid_budget_continuation}

  @doc """
  Adopts a trusted cached analysis into a consumer's continuing seed.

  Supply every normalized numeric Analysis and XML reader limit in `opts`. Any stricter limit
  fails explicitly; the cached computational proof is not rerun. The cache owner
  must establish the same physical decoded source and own its backing throughout
  adoption. Its slot/receipt controls one transfer per consumer. This function
  charges only the recorded lexical allocation, never the caller-owned root body.
  """
  def cached_result(%__MODULE__{} = analysis, opts, seed) do
    opts = Map.new(opts)

    with true <-
           Enum.all?(Map.keys(analysis.limits), &Map.has_key?(opts, &1)) ||
             {:error, :invalid_limits},
         {:ok, limits} <- Limits.new(opts),
         :ok <- cached_limits(analysis.limits, limits),
         {:ok, budget} <- validate_budget(Budget.new(limits), seed),
         :ok <- cached_allocation(analysis),
         {:ok, budget} <-
           validate_budget(
             %{analysis.allocation.seed | limit: budget.limit, caps: budget.caps},
             budget
           ),
         {:ok, key, budget} <- lexical_key_result(opts, budget),
         true <- key == analysis.lexical_key || {:error, :incompatible_source_options},
         {:ok, budget} <-
           Budget.charge(
             budget,
             analysis.allocation.retained + Budget.cost(:context),
             Map.to_list(analysis.allocation.counts)
           ) do
      {:ok,
       %{
         analysis
         | budget: budget,
           limits: limits,
           lexical_key: key,
           source_options: source_options(opts),
           allocation: allocation(seed, budget)
       }}
    end
  end

  def cached_result(_analysis, _opts, _seed), do: {:error, :invalid_cached_analysis}

  defp allocation(seed, budget) do
    %{
      seed: seed,
      retained: budget.retained - seed.retained,
      counts: Map.new(budget.counts, fn {key, count} -> {key, count - seed.counts[key]} end)
    }
  end

  defp cached_limits(old, current) do
    case Enum.find(old, fn {key, value} -> current[key] < value end) do
      nil -> :ok
      {key, _value} -> {:error, {:limit, {:cached_analysis, key}}}
    end
  end

  defp cached_allocation(%{
         allocation: %{seed: %Budget{} = seed, retained: retained, counts: counts},
         budget: %Budget{} = budget,
         limits: limits,
         lexical_key: key
       })
       when is_integer(retained) and retained >= 0 and is_map(counts) and not is_nil(key) do
    with {:ok, ^limits} <- Limits.new(limits),
         {:ok, _seed} <- validate_budget(Budget.new(limits), seed),
         {:ok, _budget} <- validate_budget(seed, budget) do
      valid =
        retained == budget.retained - seed.retained and
          Map.keys(counts) == Map.keys(budget.counts) and
          Enum.all?(counts, fn {key, count} ->
            is_integer(count) and count >= 0 and count == budget.counts[key] - seed.counts[key]
          end)

      if valid, do: :ok, else: {:error, :invalid_cached_analysis}
    else
      _error -> {:error, :invalid_cached_analysis}
    end
  end

  defp cached_allocation(_analysis), do: {:error, :invalid_cached_analysis}

  def occurrences(%__MODULE__{} = analysis, context \\ %{}) do
    with {:ok, collection} <- occurrences_result(analysis, context),
         do: {:ok, collection.occurrences}
  end

  def occurrences_result(%__MODULE__{} = analysis, context \\ %{}),
    do:
      occurrences_result(analysis, context, %{
        source_revision: analysis.revision,
        budget: analysis.budget
      })

  def occurrences_result(%__MODULE__{} = analysis, context, continuation) do
    with {:ok, budget} <- continuation_budget(analysis, continuation),
         {:ok, context} <- context_options(analysis, context),
         {:ok, refs, budget} <-
           Interpretation.run(analysis, Map.delete(context, :analysis_budget), budget) do
      {:ok, %{occurrences: refs, budget: budget, source_revision: analysis.revision}}
    end
  end

  def css_groups(%__MODULE__{} = analysis, context \\ %{}) do
    with {:ok, collection} <- css_groups_result(analysis, context), do: {:ok, collection.groups}
  end

  def css_groups_result(%__MODULE__{} = analysis, context \\ %{}) do
    with {:ok, context} <- context_options(analysis, context),
         {:ok, groups, budget} <- Interpretation.css_groups(analysis, context, analysis.budget) do
      {:ok, %{groups: groups, budget: budget, source_revision: analysis.revision}}
    end
  end

  def bind(%{occurrences: refs, budget: budget} = collection, resolver)
      when is_function(resolver, 1) do
    refs
    |> Enum.reduce_while({:ok, [], budget}, fn ref, {:ok, bound, budget} ->
      with {:ok, budget} <- Budget.charge(budget, Budget.cost(:occurrence)) do
        {:cont, {:ok, [Occurrence.bind(ref, resolver.(ref)) | bound], budget}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bound, budget} ->
        {:ok, %{collection | occurrences: Enum.reverse(bound), budget: budget}}

      error ->
        error
    end
  end

  def continuation_budget(
        %__MODULE__{budget: base, revision: revision},
        %{source_revision: revision, budget: %Budget{} = budget}
      ) do
    validate_budget(base, budget)
  end

  def continuation_budget(_analysis, _continuation), do: {:error, :invalid_budget_continuation}

  defp validate_budget(base, %Budget{} = budget) do
    valid =
      budget.limit == base.limit and budget.caps == base.caps and budget.scratch == 0 and
        is_integer(budget.retained) and is_integer(budget.peak) and is_map(budget.counts) and
        budget.retained >= base.retained and budget.peak >= base.peak and
        budget.peak >= budget.retained and budget.peak <= budget.limit and
        Map.keys(budget.counts) == Map.keys(base.counts) and
        Enum.all?(base.counts, fn {key, value} ->
          n = budget.counts[key]
          is_integer(n) and n >= value and n <= budget.caps[key]
        end)

    if valid, do: {:ok, budget}, else: {:error, :invalid_budget_continuation}
  end

  defp validate_budget(_base, _budget), do: {:error, :invalid_budget_continuation}

  @doc false
  def policy_scratch(tag) do
    Enum.reduce(tag.attributes, 512, fn attr, bytes ->
      value_bytes =
        if attr.name in ["rel", "type", "as", "crossorigin", "http-equiv"],
          do: byte_size(attr.decoded),
          else: 0

      bytes + 128 * (byte_size(attr.name) + value_bytes)
    end)
  end

  @doc false
  def adopt(budget, term), do: adopt_term(budget, term, 0)

  defp adopt_term(_budget, _term, depth) when depth > 256, do: {:error, {:limit, :analysis_depth}}

  defp adopt_term(budget, term, _depth) when is_binary(term),
    do: Budget.charge(budget, byte_size(term) + Budget.cost(:binary))

  defp adopt_term(budget, [], _depth), do: {:ok, budget}

  defp adopt_term(budget, [head | tail], depth) do
    with {:ok, budget} <- Budget.charge(budget, Budget.cost(:list_cell)),
         {:ok, budget} <- adopt_term(budget, head, depth + 1),
         do: adopt_term(budget, tail, depth)
  end

  defp adopt_term(budget, term, depth) when is_map(term) do
    with {:ok, budget} <- Budget.charge(budget, Budget.cost(:json_container)),
         do: adopt_map(budget, :maps.iterator(term), depth)
  end

  defp adopt_term(budget, term, depth) when is_tuple(term) do
    with {:ok, budget} <- Budget.charge(budget, 16 + 8 * tuple_size(term)),
         do: adopt_tuple(budget, term, 0, depth)
  end

  defp adopt_term(budget, _term, _depth), do: Budget.charge(budget, 16)

  defp adopt_map(budget, iterator, depth) do
    case :maps.next(iterator) do
      :none ->
        {:ok, budget}

      {key, value, next} ->
        with {:ok, budget} <- Budget.charge(budget, Budget.cost(:map_entry)),
             {:ok, budget} <- adopt_term(budget, key, depth + 1),
             {:ok, budget} <- adopt_term(budget, value, depth + 1),
             do: adopt_map(budget, next, depth)
    end
  end

  defp adopt_tuple(budget, tuple, index, _depth) when index == tuple_size(tuple),
    do: {:ok, budget}

  defp adopt_tuple(budget, tuple, index, depth) do
    with {:ok, budget} <- adopt_term(budget, elem(tuple, index), depth + 1),
         do: adopt_tuple(budget, tuple, index + 1, depth)
  end

  defp revision(source, options, budget) do
    bytes = :erlang.external_size(options)

    with {:ok, budget} <- Budget.reserve(budget, bytes),
         {:ok, budget} <- Budget.charge(budget, Budget.cost(:context) + Budget.cost(:binary) + 32) do
      revision =
        :crypto.hash_init(:sha256)
        |> :crypto.hash_update(<<byte_size(source)::64>>)
        |> :crypto.hash_update(source)
        |> :crypto.hash_update(:erlang.term_to_binary(options))
        |> :crypto.hash_final()

      with {:ok, budget} <- Budget.release(budget, bytes), do: {:ok, revision, budget}
    end
  end

  defp context_options(analysis, context) do
    context = Map.new(context)
    source_options = Map.take(context, Map.keys(analysis.source_options) -- [:javascript_goal])

    if Enum.all?(source_options, fn
         {:fetch_kind, value} when analysis.mode == :json ->
           value in [:manifest, :speculation_rules, :source_map]

         {:content_type, value} ->
           compatible_type?(value, analysis.source_options[:content_type])

         {:headers, value} ->
           (value || []) == analysis.source_options[:headers]

         {key, value} ->
           value == analysis.source_options[key]
       end) do
      {:ok, Map.merge(analysis.source_options, context)}
    else
      {:error, :incompatible_source_options}
    end
  end

  def context_key(context), do: Interpretation.context_key(Map.new(context))

  def css_facts(%__MODULE__{} = analysis) do
    for {id, %{kind: :css, facts: facts}} <- analysis.regions, into: %{}, do: {id, facts}
  end

  def render(analysis, occurrences, resolver, opts \\ []) do
    case render_with_stats(analysis, occurrences, resolver, opts) do
      {:ok, source, _stats} -> {:ok, source}
      error -> error
    end
  end

  def render_with_stats(%__MODULE__{} = analysis, occurrences, resolver, opts \\ []),
    do: Render.run(analysis, occurrences, resolver, opts)

  def online_fallback(occurrence), do: {:online, occurrence.url}

  defp source_options(opts) do
    %{
      content_type: opts[:content_type],
      headers: opts[:headers] || [],
      fetch_kind: opts[:fetch_kind],
      javascript_goal: opts[:javascript_goal]
    }
  end

  defp lexical_options(:json, opts), do: Map.delete(source_options(opts), :fetch_kind)
  defp lexical_options(_mode, opts), do: source_options(opts)

  defp compatible_type?(left, right) do
    MediaType.normalize(left) == MediaType.normalize(right) or
      (MediaType.javascript?(left) and MediaType.javascript?(right))
  end

  defp valid_source(source, opts) do
    cond do
      not String.valid?(source) -> {:error, :invalid_utf8}
      opts[:headers] != nil and not is_list(opts[:headers]) -> {:error, :invalid_headers}
      true -> :ok
    end
  end
end
