defmodule Crawler.Analysis.Occurrence do
  @moduledoc false

  @enforce_keys [:id, :region, :value, :url, :context]
  defstruct [
    :id,
    :region,
    :span,
    :value,
    :url,
    :fragment,
    :context,
    :target,
    :source_revision,
    :source_mode,
    :source_role,
    :srcdoc,
    :robots_nofollow,
    :namespace,
    :source_base,
    :document_base,
    :element,
    :encoding,
    :integrity,
    metadata: %{}
  ]

  def bind(%__MODULE__{} = occurrence, target), do: %{occurrence | target: target}

  def handler_element(%__MODULE__{
        span: nil,
        metadata: %{css_picture: %{}},
        url: url,
        element: attr
      }),
      do: {attr || "href", url}

  def handler_element(%__MODULE__{value: value, url: url, element: attr}) do
    if value == url, do: {attr || "href", url}, else: {"link", value, attr || "href", url}
  end

  def handler_options(%__MODULE__{context: context} = occurrence, options) do
    carried =
      context
      |> Enum.reject(fn
        {_key, nil} -> true
        {:credentials, :include} -> context[:javascript_goal] != :module
        {:page_open, true} -> true
        _entry -> false
      end)
      |> Map.new()

    options =
      if occurrence.srcdoc,
        do: options |> Map.delete(:headers) |> Map.put(:content_type, "text/html"),
        else: options

    options = Map.delete(options, :robots_nofollow)

    options =
      if occurrence.robots_nofollow, do: Map.put(options, :robots_nofollow, true), else: options

    options =
      if is_binary(occurrence.source_base),
        do: Map.put(options, :referrer_url, occurrence.source_base),
        else: options

    options =
      options
      |> Map.drop([
        :javascript_goal,
        :cookie_navigation,
        :import_map,
        :document_base,
        :document_url,
        :worker_base,
        :link_html_tag,
        :fetch_kind,
        :json_span,
        :credentials,
        :page_open,
        :style_group,
        :srcdoc,
        :css_tokens,
        :css_references,
        :css_revision,
        :managed_css_snapshot,
        :source_map_regions,
        :source_map_notes,
        :source_map_note,
        :analysis_budget,
        :budget,
        :analysis,
        :document_styles,
        :document_style_id,
        :css_sheet_id
      ])
      |> Map.merge(carried)

    options =
      if occurrence.encoding == :json,
        do: Map.put(options, :json_span, occurrence.span),
        else: options

    case {occurrence.metadata[:depth_delta], options[:depth]} do
      {delta, depth} when is_integer(delta) and is_integer(depth) ->
        Map.put(options, :depth, max(depth + delta, 0))

      _other ->
        options
    end
  end
end
