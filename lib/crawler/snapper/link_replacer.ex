defmodule Crawler.Snapper.LinkReplacer do
  @moduledoc """
  Replaces links found in a page so they work offline.

  Removes integrity metadata from rewritten script, stylesheet, modulepreload,
  and script or style preload references because saved resource bytes can change.
  """

  alias Crawler.HTMLReferences
  alias Crawler.HTMLSpans
  alias Crawler.Linker
  alias Crawler.MediaType
  alias Crawler.Parser
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.Guarder
  alias Crawler.Parser.ScriptReferences
  alias Crawler.Parser.SourceMap
  alias Crawler.Parser.SpeculationRules
  alias Crawler.Snapper.LinkReplacer.Css
  alias Crawler.Snapper.LinkReplacer.Html
  alias Crawler.Snapper.LinkReplacer.Json
  alias Crawler.Snapper.LinkReplacer.RawText
  alias Crawler.Snapper.LinkReplacer.Tokens
  alias Crawler.URL

  @doc """
  Replaces links found in a page so they work offline.

  ## Examples

      iex> LinkReplacer.replace_links(
      iex>   "<a href='http://another.domain/page.html'></a>",
      iex>   %{
      iex>     url: "http://main.domain/dir/page",
      iex>     depth: 1,
      iex>     max_depths: 2,
      iex>     html_tag: "a",
      iex>     content_type: "text/html",
      iex>   }
      iex> )
      {:ok, "<a href='../../../another.domain/page.html'></a>"}

      iex> LinkReplacer.replace_links(
      iex>   "<a href='http://another.domain/dir/page.html'></a>",
      iex>   %{
      iex>     url: "http://main.domain/page",
      iex>     depth: 1,
      iex>     max_depths: 2,
      iex>     html_tag: "a",
      iex>     content_type: "text/html",
      iex>   }
      iex> )
      {:ok, "<a href='../../another.domain/dir/page.html'></a>"}

      iex> LinkReplacer.replace_links(
      iex>   "<a href='http://another.domain/dir/page'></a>",
      iex>   %{
      iex>     url: "http://main.domain/dir/page",
      iex>     depth: 1,
      iex>     max_depths: 2,
      iex>     html_tag: "a",
      iex>     content_type: "text/html",
      iex>   }
      iex> )
      {:ok, "<a href='../../../another.domain/dir/page/__index.html'></a>"}

      iex> LinkReplacer.replace_links(
      iex>   "<a href='/dir/page2.html'></a>",
      iex>   %{
      iex>     url: "http://main.domain/dir/page",
      iex>     referrer_url: "http://main.domain/dir/page",
      iex>     depth: 1,
      iex>     max_depths: 2,
      iex>     html_tag: "a",
      iex>     content_type: "text/html",
      iex>   }
      iex> )
      {:ok, "<a href='../../../main.domain/dir/page2.html'></a>"}
  """
  def replace_links(body, opts) do
    cond do
      opts[:fetch_kind] in [:manifest, :speculation_rules, :source_map] ->
        {:ok, Json.replace_spans(body, located_replacements(body, opts))}

      MediaType.javascript?(opts[:content_type]) ->
        {:ok, javascript_body(body, opts)}

      Guarder.pass?(opts) ->
        {:ok, html_body(body, opts)}

      true ->
        {:ok, body}
    end
  end

  defp html_body(body, opts) do
    opts = put_srcdoc_style_group(body, opts)
    opts = Map.put(opts, :document_styles, Parser.document_styles(body, opts))
    raw_links = links(body, opts)
    {body, saved} = RawText.protect(body, opts)
    document_links = if saved == [], do: raw_links, else: links(body, opts)

    body
    |> rewrite_srcdocs(opts)
    |> rewrite_body(document_links, opts)
    |> drop_parsed_base(opts)
    |> RawText.restore(saved, fn source, source_opts ->
      rewrite_opts = opts |> Map.delete(:javascript_goal) |> Map.merge(source_opts)

      cond do
        # An unparsed response keeps the original script bytes.
        source_opts[:fetch_kind] == :speculation_rules and Guarder.pass?(opts) ->
          rewrite_inline_rules(source, opts, source_opts)

        MediaType.javascript?(source_opts[:content_type]) ->
          javascript_body(source, rewrite_opts)

        true ->
          rewrite_body(
            source,
            style_rewrite_links(source, rewrite_opts, source_opts),
            rewrite_opts
          )
      end
    end)
  end

  # A parsed page drops base because its addresses now point at saved files.
  # An unparsed response keeps base so the addresses that were left unchanged
  # still resolve against the document.
  defp drop_parsed_base(body, opts) do
    if Guarder.pass?(opts), do: Html.drop_base(body, opts), else: body
  end

  defp javascript_body(body, opts) do
    if Guarder.pass?(opts), do: ScriptReferences.rewrite(body, opts), else: body
  end

  defp links(body, opts) do
    body
    |> Parser.parse_links(Map.put(opts, :css_sheet, :rewrite), &get_link/2)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(
      fn {raw, _resolved} -> byte_size(raw) end,
      :desc
    )
    |> Enum.map(fn {raw, resolved} ->
      {raw, Linker.offline_link(opts[:url], with_fragment(resolved, raw))}
    end)
  end

  # An SVG paint server such as url(#id) points at this drawing. Rewriting it
  # with another link's matching fragment would send the paint at an offline file.
  defp source_links(links, %{svg_style: true}) do
    Enum.reject(links, fn {raw, _offline} -> HTMLReferences.local_reference?(raw) end)
  end

  defp source_links(links, _source_opts), do: links

  # The first document walk records style elements before later elements use them.
  # Preview each original style body again once that group is complete.
  defp style_rewrite_links(source, opts, source_opts) do
    source
    |> CssParser.spans(css_replace_opts(opts))
    |> Enum.flat_map(&style_link(&1, opts))
    |> Enum.uniq()
    |> Enum.sort_by(fn {raw, _offline} -> byte_size(raw) end, :desc)
    |> source_links(source_opts)
  end

  defp style_link(token, opts) do
    base = opts[:referrer_url] || opts[:url]

    case URL.resolve(token.value, base) do
      {:ok, resolved} ->
        [{token.value, Linker.offline_link(opts[:url], with_fragment(resolved, token.value))}]

      :skip ->
        []
    end
  end

  defp rewrite_srcdocs(body, opts) do
    if srcdoc_document?(body, opts) do
      nested = srcdoc_opts(body, opts)

      edits =
        body
        |> HTMLSpans.tags()
        |> Enum.flat_map(&srcdoc_edit(body, &1, nested))

      HTMLSpans.rewrite(body, edits)
    else
      body
    end
  end

  defp srcdoc_document?(body, opts) when is_binary(body) do
    Guarder.pass?(opts) and
      (MediaType.html?(opts[:content_type]) or MediaType.svg?(opts[:content_type]))
  end

  defp srcdoc_document?(_body, _opts), do: false

  # Style elements are remembered under the srcdoc group. The rewrite opts must
  # use that same group, not the parent document URL.
  defp put_srcdoc_style_group(body, %{srcdoc: true} = opts) do
    case Parser.assigned_style_group(body, opts) do
      group when is_binary(group) and group != "" -> Map.put(opts, :style_group, group)
      _other -> opts
    end
  end

  defp put_srcdoc_style_group(_body, opts), do: opts

  defp srcdoc_opts(body, opts) do
    location = opts[:document_url] || opts[:referrer_url] || opts[:url]
    base = Parser.with_document_base(body, opts)

    opts
    |> Map.put(:content_type, "text/html")
    |> Map.put(:html_tag, "a")
    |> Map.put(:referrer_url, base[:referrer_url] || opts[:url])
    |> put_srcdoc_location(location)
    |> Map.delete(:robots_nofollow)
    |> Map.delete(:headers)
    |> Map.delete(:javascript_goal)
    |> Map.delete(:import_map)
    |> Map.delete(:document_base)
    |> Map.delete(:worker_base)
    |> Map.delete(:fetch_kind)
    |> Map.delete(:json_span)
    |> Map.delete(:style_group)
    |> Map.delete(:document_styles)
    |> Map.delete(:document_style_id)
    |> Map.put(:srcdoc, true)
  end

  defp put_srcdoc_location(opts, url) when is_binary(url) and url != "",
    do: Map.put(opts, :document_url, url)

  defp put_srcdoc_location(opts, _url), do: opts

  defp srcdoc_edit(
         body,
         %{name: "iframe", namespace: :html, closing?: false, in_template?: false} = tag,
         opts
       ) do
    case HTMLSpans.attribute(tag, "srcdoc") do
      %{value_span: span, decoded: decoded} when is_tuple(span) ->
        {:ok, rewritten} = replace_links(decoded, opts)
        if rewritten == decoded, do: [], else: [{span, srcdoc_value(body, span, rewritten)}]

      _attr ->
        []
    end
  end

  defp srcdoc_edit(_body, _tag, _opts), do: []

  # An unquoted value cannot contain the spaces in the decoded document.
  defp srcdoc_value(body, {start, _length}, rewritten) do
    escaped = escape_attribute(rewritten)

    if start > 0 and :binary.at(body, start - 1) in [?", ?'] do
      escaped
    else
      "\"" <> escaped <> "\""
    end
  end

  defp escape_attribute(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp rewrite_body(body, [], opts), do: finish_css(body, opts)

  defp rewrite_body(body, links, opts) do
    prefix = Tokens.prefix([body | Enum.map(links, &elem(&1, 1))], "L")

    {body, replacements} =
      links
      |> Enum.with_index()
      |> Enum.reduce({body, %{}}, fn {{raw, offline}, index}, {body, replacements} ->
        token = Tokens.at(prefix, index)
        {modify_body(body, opts, {raw, token}), Map.put(replacements, token, offline)}
      end)

    tokens = Map.keys(replacements)

    body
    |> Html.drop_rewritten_integrity(tokens, opts)
    |> String.replace(tokens, &Map.fetch!(replacements, &1))
    |> finish_css(opts)
  end

  defp finish_css(body, opts) do
    if MediaType.css?(opts[:content_type]) and Guarder.pass?(opts) do
      SourceMap.rewrite_css(body, opts)
    else
      body
    end
  end

  defp located_replacements(body, opts) do
    spans =
      body
      |> Parser.parse_links(opts, &located_link/2)
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    if opts[:fetch_kind] == :source_map and spans != [] do
      spans ++ SourceMap.root_clear_spans(body, opts)
    else
      spans
    end
  end

  defp located_link(link, link_opts) do
    case link_opts[:json_span] do
      {start, length} ->
        {raw, resolved} = get_link(link, link_opts)
        offline = Linker.offline_link(link_opts[:url], with_fragment(resolved, raw))
        {start, length, offline}

      _span ->
        nil
    end
  end

  # fetch_kind stays unset, so an inline ruleset url keeps the document base.
  defp rewrite_inline_rules(source, page_opts, source_opts) do
    rules_opts = %{
      url: page_opts[:url],
      referrer_url: source_opts[:referrer_url] || source_opts[:document_base],
      document_base: source_opts[:document_base]
    }

    spans =
      Enum.map(SpeculationRules.entries(source, rules_opts), fn {raw, resolved, start, length,
                                                                 _action} ->
        {start, length, Linker.offline_link(page_opts[:url], with_fragment(resolved, raw))}
      end)

    Json.replace_spans(source, spans)
  end

  defp get_link({_, url}, _opts), do: {url, url}
  defp get_link({_, link, _, url}, _opts), do: {link, url}

  defp modify_body(body, _opts, {"", _offline}), do: body

  defp modify_body(body, opts, {raw, offline}) do
    cond do
      MediaType.css?(opts[:content_type]) ->
        Css.replace(body, raw, offline, css_replace_opts(opts))

      true ->
        Html.replace(body, raw, offline, opts)
    end
  end

  defp css_replace_opts(opts) do
    [
      entity_quotes: false,
      mode: :stylesheet,
      css_sheet: :replace,
      scope: opts[:scope],
      generation: opts[:generation],
      queue: opts[:queue],
      url: opts[:url],
      referrer_url: opts[:referrer_url],
      style_group: opts[:style_group],
      document_url: opts[:document_url],
      document_styles: opts[:document_styles],
      document_style_id: opts[:document_style_id]
    ]
  end

  defp with_fragment(resolved, raw) do
    case fragment_suffix(raw) do
      "" ->
        resolved

      fragment ->
        if String.ends_with?(resolved, fragment) do
          resolved
        else
          strip_fragment(resolved) <> fragment
        end
    end
  end

  defp fragment_suffix(value) do
    case String.split(URL.sanitize(value), "#", parts: 2) do
      [_base, fragment] -> "#" <> fragment
      _ -> ""
    end
  end

  defp strip_fragment(value) do
    value |> String.split("#", parts: 2) |> hd()
  end
end
