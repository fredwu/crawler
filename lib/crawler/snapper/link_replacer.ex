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
          rewrite_body(source, source_links(raw_links, source_opts), rewrite_opts)
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
    |> Parser.parse_links(opts, &get_link/2)
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

  defp srcdoc_opts(body, opts) do
    base = Parser.with_document_base(body, opts)

    opts
    |> Map.put(:content_type, "text/html")
    |> Map.put(:html_tag, "a")
    |> Map.put(:referrer_url, base[:referrer_url] || opts[:url])
    |> Map.delete(:robots_nofollow)
    |> Map.delete(:headers)
    |> Map.delete(:javascript_goal)
    |> Map.delete(:import_map)
    |> Map.delete(:document_base)
    |> Map.delete(:worker_base)
    |> Map.delete(:fetch_kind)
    |> Map.delete(:json_span)
  end

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

  # Inline rules belong to the document. A ruleset base applies only to a rules file.
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
        Css.replace(body, raw, offline, entity_quotes: false)

      true ->
        Html.replace(body, raw, offline, opts)
    end
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
