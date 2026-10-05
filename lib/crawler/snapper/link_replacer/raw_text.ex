defmodule Crawler.Snapper.LinkReplacer.RawText do
  @moduledoc false

  alias Crawler.HTMLReferences
  alias Crawler.HTMLSpans
  alias Crawler.MediaType
  alias Crawler.Snapper.LinkReplacer.Tokens

  def protect(body, opts) do
    if MediaType.css?(opts[:content_type]) or MediaType.javascript?(opts[:content_type]) do
      {body, []}
    else
      prefix = Tokens.prefix([body], "R")

      body
      |> HTMLSpans.tags()
      |> Enum.filter(& &1.content_span)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce({body, []}, &protect_region(&1, &2, opts, prefix))
    end
  end

  def restore(body, saved, rewrite) do
    Enum.reduce(saved, body, fn {token, source, source_opts}, body ->
      source = if source_opts, do: rewrite.(source, source_opts), else: source
      String.replace(body, token, source)
    end)
  end

  defp protect_region({tag, index}, {body, saved}, opts, prefix) do
    {start, length} = tag.content_span
    source = binary_part(body, start, length)
    source_opts = source_options(tag, opts)
    token = Tokens.at(prefix, index)
    head = binary_part(body, 0, start)
    tail = binary_part(body, start + length, byte_size(body) - start - length)

    {head <> token <> tail, [{token, source, source_opts} | saved]}
  end

  defp source_options(%{in_template?: true}, _opts), do: nil

  defp source_options(tag, opts) do
    attrs = Enum.map(tag.attributes, &{&1.name, &1.decoded})

    cond do
      tag.name == "style" and HTMLReferences.enabled?(opts, "css") ->
        %{content_type: "text/css"}

      tag.name == "script" and HTMLReferences.enabled?(opts, "js") and
          HTMLReferences.script_source(attrs) == :inline ->
        %{
          content_type: "application/javascript",
          javascript_goal: HTMLReferences.script_goal(attrs)
        }

      true ->
        nil
    end
  end
end
