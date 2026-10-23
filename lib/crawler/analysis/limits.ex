defmodule Crawler.Analysis.Limits do
  @moduledoc false

  @defaults %{
    max_bytes: 10_485_760,
    max_total_bytes: 41_943_040,
    max_regions: 100_000,
    max_depth: 16,
    max_facts: 200_000,
    max_occurrences: 100_000,
    max_edits: 100_000,
    max_output_bytes: 41_943_040
  }

  @xml_keys [:max_xml_depth, :max_xml_tokens, :max_xml_attributes]

  def new(opts) do
    defaults = Map.merge(@defaults, Map.take(Crawler.Limits.defaults(), @xml_keys))
    limits = Map.merge(defaults, Map.take(Map.new(opts), Map.keys(defaults)))

    if Enum.all?(limits, fn
         {:max_bytes, n} -> is_integer(n) and n >= 0
         {_key, n} -> is_integer(n) and n > 0
       end),
       do: {:ok, limits},
       else: {:error, :invalid_limits}
  end

  def check(value, limit, name) do
    if value <= limit, do: :ok, else: {:error, {:limit, name}}
  end
end
