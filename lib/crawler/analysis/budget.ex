defmodule Crawler.Analysis.Budget do
  @moduledoc """
  Pure allocation authority for one analysis pipeline. The input body backing is
  owned by the caller; additional retained values and overlapping scratch share
  `max_total_bytes`. Counters are cumulative and are never refunded.
  """

  @enforce_keys [:limit, :caps]
  defstruct [
    :limit,
    :caps,
    retained: 0,
    scratch: 0,
    peak: 0,
    counts: %{facts: 0, regions: 0, occurrences: 0, edits: 0}
  ]

  @type t :: %__MODULE__{
          limit: non_neg_integer() | :infinity,
          caps: map(),
          retained: non_neg_integer(),
          scratch: non_neg_integer(),
          peak: non_neg_integer(),
          counts: map()
        }
  @type result :: {:ok, t()} | {:error, {:limit, atom()}} | {:error, :invalid_budget_charge}

  @errors %{
    facts: :lexical_facts,
    regions: :source_regions,
    occurrences: :occurrences,
    edits: :edits
  }
  @tariffs %{
    region: 512,
    tag: 512,
    attribute: 320,
    segment: 128,
    token: 384,
    json_scalar: 64,
    json_container: 128,
    json_pair: 128,
    binding: 512,
    use: 512,
    registration: 512,
    context: 512,
    occurrence: 1024,
    edit: 192,
    list_cell: 16,
    map_entry: 96,
    frame: 256,
    binary: 64
  }

  @doc "Accepts already-normalized Analysis limits; applies no defaults."
  def new(limits) do
    %__MODULE__{
      limit: Map.fetch!(limits, :max_total_bytes),
      caps: %{
        facts: Map.fetch!(limits, :max_facts),
        regions: Map.fetch!(limits, :max_regions),
        occurrences: Map.fetch!(limits, :max_occurrences),
        edits: Map.fetch!(limits, :max_edits)
      }
    }
  end

  @doc "For existing standalone wrappers only; native parser limits still apply."
  def unlimited do
    %__MODULE__{limit: :infinity, caps: Map.new(@errors, fn {key, _} -> {key, :infinity} end)}
  end

  @doc "Structure tariff; variable payload backing bytes must be charged separately."
  def cost(kind, count \\ 1) when is_integer(count) and count >= 0,
    do: Map.fetch!(@tariffs, kind) * count

  @doc "Reserve permanent allocation and cumulative counters before constructing it."
  @spec charge(t(), non_neg_integer(), keyword(non_neg_integer())) :: result()
  def charge(budget, bytes, counters \\ [])

  def charge(%__MODULE__{} = budget, bytes, counters) when is_integer(bytes) and bytes >= 0 do
    with {:ok, counts} <- count_changes(budget, counters),
         :ok <- capacity(budget, bytes) do
      {:ok, peak(%{budget | retained: budget.retained + bytes, counts: counts})}
    end
  end

  def charge(_budget, _bytes, _counters), do: {:error, :invalid_budget_charge}

  def count(budget, key, amount \\ 1), do: charge(budget, 0, [{key, amount}])

  @doc "Reserve overlapping scratch before work. The caller retains its byte token."
  @spec reserve(t(), non_neg_integer()) :: result()
  def reserve(%__MODULE__{} = budget, bytes) when is_integer(bytes) and bytes >= 0 do
    with :ok <- capacity(budget, bytes),
         do: {:ok, peak(%{budget | scratch: budget.scratch + bytes})}
  end

  def reserve(_budget, _bytes), do: {:error, :invalid_budget_charge}

  @doc "Convert this reservation into retained bytes; unused capacity is released."
  @spec settle(t(), non_neg_integer(), non_neg_integer()) :: result()
  def settle(%__MODULE__{} = budget, reserved, retained)
      when is_integer(reserved) and reserved >= 0 and is_integer(retained) and retained >= 0 do
    if reserved <= budget.scratch and retained <= reserved do
      {:ok, %{budget | scratch: budget.scratch - reserved, retained: budget.retained + retained}}
    else
      {:error, :invalid_budget_charge}
    end
  end

  def settle(_budget, _reserved, _retained), do: {:error, :invalid_budget_charge}

  def release(budget, reserved), do: settle(budget, reserved, 0)

  @doc "Release retained authority only once the corresponding values cease to be live."
  def refund(%__MODULE__{} = budget, bytes) when is_integer(bytes) and bytes >= 0 do
    if bytes <= budget.retained,
      do: {:ok, %{budget | retained: budget.retained - bytes}},
      else: {:error, :invalid_budget_charge}
  end

  def refund(_budget, _bytes), do: {:error, :invalid_budget_charge}

  def available(%__MODULE__{limit: :infinity}), do: :infinity
  def available(%__MODULE__{} = budget), do: budget.limit - budget.retained - budget.scratch

  def snapshot(%__MODULE__{} = budget),
    do: Map.take(budget, [:limit, :retained, :scratch, :peak, :counts, :caps])

  defp capacity(%{limit: :infinity}, _bytes), do: :ok

  defp capacity(budget, bytes) do
    if budget.retained + budget.scratch + bytes <= budget.limit,
      do: :ok,
      else: {:error, {:limit, :analysis_bytes}}
  end

  defp peak(budget), do: %{budget | peak: max(budget.peak, budget.retained + budget.scratch)}

  defp count_changes(budget, counters) do
    Enum.reduce_while(counters, {:ok, budget.counts}, fn
      {key, amount}, {:ok, counts}
      when is_map_key(@errors, key) and is_integer(amount) and amount >= 0 ->
        next = Map.fetch!(counts, key) + amount
        cap = Map.fetch!(budget.caps, key)

        if cap == :infinity or next <= cap,
          do: {:cont, {:ok, Map.put(counts, key, next)}},
          else: {:halt, {:error, {:limit, Map.fetch!(@errors, key)}}}

      _entry, _acc ->
        {:halt, {:error, :invalid_budget_charge}}
    end)
  end
end
