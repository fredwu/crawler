defmodule Crawler.Limits do
  @moduledoc false

  @defaults %{
    max_body: 10_485_760,
    max_pending: 1_024,
    max_frontier_bytes: 16_777_216,
    max_representations: 10_000,
    max_interpretations: 20_000,
    max_retained_bytes: 67_108_864,
    max_queue_tickets: 32,
    max_tracked_queues: 1_024,
    max_control_documents: 128,
    max_control_bytes: 33_554_432,
    max_control_depth: 16,
    max_control_entries: 50_000,
    max_control_token_bytes: 65_536,
    max_analysis_bytes: 20_000_000,
    max_analysis_regions: 100_000,
    max_analysis_depth: 16,
    max_analysis_facts: 200_000,
    max_analysis_occurrences: 100_000,
    max_analysis_edits: 100_000,
    max_xml_depth: 256,
    max_xml_tokens: 100_000,
    max_xml_attributes: 1_024,
    max_css_work: 100_000,
    max_css_pictures: 10_000,
    max_css_depth: 256,
    max_manifest_bytes: 4_194_304,
    max_staged_bytes: 268_435_456,
    max_staged_metadata_bytes: 134_217_728,
    max_file_bytes: 33_554_432,
    max_files: 10_000,
    max_artifacts: 10_000,
    max_edges: 100_000,
    max_fs_entries: 40_000,
    max_fs_journal_bytes: 8_388_608,
    attempt_timeout: 30_000,
    run_timeout: 600_000
  }

  @cookie_keys [
    :max_cookies,
    :max_cookies_per_site,
    :max_cookie_bytes,
    :max_cookie_jar_bytes,
    :max_cookie_updates
  ]

  def defaults(extra_defaults \\ %{}) do
    @defaults
    |> Map.merge(Map.new(extra_defaults))
    |> Map.new(fn {key, value} -> {key, Application.get_env(:crawler, key, value)} end)
  end

  def validate!(opts, extra_defaults \\ %{}) do
    defaults = defaults(extra_defaults)
    opts = Map.merge(defaults, Map.new(opts))

    Enum.each(Map.keys(defaults), fn key ->
      value = Map.fetch!(opts, key)
      minimum = if key == :max_body, do: 0, else: 1

      if not is_integer(value) or value < minimum do
        expectation = if minimum == 0, do: "a non-negative integer", else: "a positive integer"
        raise ArgumentError, "#{key} must be #{expectation}"
      end
    end)

    validate_existing_options!(opts)
    opts
  end

  def analysis(opts) do
    %{
      max_bytes: Map.fetch!(opts, :max_body),
      max_total_bytes: Map.fetch!(opts, :max_analysis_bytes),
      max_output_bytes: Map.fetch!(opts, :max_analysis_bytes),
      max_regions: Map.fetch!(opts, :max_analysis_regions),
      max_depth: Map.fetch!(opts, :max_analysis_depth),
      max_facts: Map.fetch!(opts, :max_analysis_facts),
      max_occurrences: Map.fetch!(opts, :max_analysis_occurrences),
      max_edits: Map.fetch!(opts, :max_analysis_edits),
      max_xml_depth: Map.fetch!(opts, :max_xml_depth),
      max_xml_tokens: Map.fetch!(opts, :max_xml_tokens),
      max_xml_attributes: Map.fetch!(opts, :max_xml_attributes)
    }
  end

  def decoded_context(opts) do
    Enum.min([
      Map.fetch!(opts, :max_frontier_bytes),
      Map.fetch!(opts, :max_analysis_bytes),
      Map.fetch!(opts, :max_retained_bytes),
      Crawler.Store.DecodedSource.maximum_context_bytes()
    ])
  end

  def export(opts) do
    opts
    |> Map.take([
      :max_representations,
      :max_artifacts,
      :max_edges,
      :max_manifest_bytes,
      :max_staged_bytes,
      :max_staged_metadata_bytes,
      :max_file_bytes,
      :max_files
    ])
    |> Map.put(:max_targets, Map.fetch!(opts, :max_interpretations))
  end

  def filesystem(opts) do
    [
      max_bytes: Map.fetch!(opts, :max_staged_bytes),
      max_file_bytes: Map.fetch!(opts, :max_file_bytes),
      max_metadata_bytes: Map.fetch!(opts, :max_file_bytes),
      max_files: Map.fetch!(opts, :max_files),
      max_entries: Map.fetch!(opts, :max_fs_entries),
      max_journal_bytes: Map.fetch!(opts, :max_fs_journal_bytes)
    ]
  end

  def css(opts) do
    [
      max_work: Map.fetch!(opts, :max_css_work),
      max_pictures: Map.fetch!(opts, :max_css_pictures),
      max_depth: Map.fetch!(opts, :max_css_depth)
    ]
  end

  def xml(opts) do
    [
      max_bytes: Map.fetch!(opts, :max_analysis_bytes),
      max_depth: Map.fetch!(opts, :max_xml_depth),
      max_tokens: Map.fetch!(opts, :max_xml_tokens),
      max_attributes: Map.fetch!(opts, :max_xml_attributes)
    ]
  end

  def cookies(opts), do: Map.take(opts, @cookie_keys)

  defp validate_existing_options!(opts) do
    Enum.each([:max_depths, :interval, :retries], fn key ->
      if Map.has_key?(opts, key) and (not is_integer(opts[key]) or opts[key] < 0) do
        raise ArgumentError, "#{key} must be a non-negative integer"
      end
    end)

    if Map.has_key?(opts, :workers) and (not is_integer(opts.workers) or opts.workers < 1) do
      raise ArgumentError, "workers must be a positive integer"
    end

    Enum.each([:max_pages, :timeout], fn key ->
      value = opts[key]

      if Map.has_key?(opts, key) and value != :infinity and
           (not is_integer(value) or value < 0) do
        raise ArgumentError, "#{key} must be a non-negative integer or :infinity"
      end
    end)
  end
end
