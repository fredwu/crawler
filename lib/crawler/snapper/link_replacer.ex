defmodule Crawler.Snapper.LinkReplacer do
  @moduledoc """
  Replaces links found in a page so they work offline.
  """

  alias Crawler.Linker
  alias Crawler.MediaType
  alias Crawler.Parser
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.JsParser

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
    new_body =
      body
      |> Parser.parse_links(opts, &get_link/2)
      |> List.flatten()
      |> Enum.reject(&(&1 == nil))
      |> Enum.sort_by(
        fn {raw, _resolved} -> raw |> variants() |> Enum.map(&byte_size/1) |> Enum.max() end,
        :desc
      )
      |> Enum.reduce(body, &modify_body(&2, opts, &1))
      |> drop_base(opts)

    {:ok, new_body}
  end

  defp drop_base(body, opts) do
    if html_document?(opts) do
      String.replace(
        body,
        ~r/<\s*\/?\s*base\b(?:[^>"']|"(?:\\.|[^"])*"|'(?:\\.|[^'])*')*>/i,
        ""
      )
    else
      body
    end
  end

  defp html_document?(opts), do: MediaType.html?(opts[:content_type])

  defp get_link({_, url}, _opts), do: {url, url}
  defp get_link({_, link, _, url}, _opts), do: {link, url}

  defp modify_body(body, opts, {raw, resolved}) do
    offline = Linker.offline_link(opts[:url], with_fragment(resolved, raw))

    Enum.reduce(variants(raw), body, fn variant, body ->
      rewrite_variant(body, variant, offline, opts)
    end)
  end

  defp rewrite_variant(body, variant, _offline, _opts) when variant == "", do: body

  defp rewrite_variant(body, variant, offline, opts) do
    if String.contains?(body, variant) do
      {body, saved} = lift_quoted_data(body)

      body
      |> replace_srcset(variant, offline)
      |> replace_image_set(variant, offline)
      |> replace_css_urls(variant, offline)
      |> replace_imports(variant, offline)
      |> replace_meta(variant, offline)
      |> replace_js(variant, offline, opts)
      |> replace_attributes(variant, offline)
      |> replace_unquoted(variant, offline)
      |> restore_quoted_data(saved)
    else
      body
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
    case String.split(value, "#", parts: 2) do
      [_base, fragment] -> "#" <> fragment
      _ -> ""
    end
  end

  defp strip_fragment(value) do
    value |> String.split("#", parts: 2) |> hd()
  end

  defp variants(raw) do
    [String.replace(raw, "&", "&amp;"), raw]
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp replace_srcset(body, variant, offline) do
    replace_in_tags(body, fn tag ->
      Regex.replace(
        ~r/((?<![\w-])(?i:imagesrcset|srcset)\s*=\s*)(["'])([^"']*)\2/,
        tag,
        fn _, attr, quote, value ->
          attr <> quote <> replace_candidate(value, variant, offline) <> quote
        end
      )
    end)
  end

  # Splice from the end. A rewritten path still contains the original
  # filename, so a later substring search would change that copy and skip
  # the rule that still has the short name.
  defp replace_image_set(body, variant, offline) do
    body
    |> CssParser.image_set_spans()
    |> Enum.reverse()
    |> Enum.reduce(body, fn {start, inner}, body ->
      splice(body, start, inner, replace_image_set_quotes(inner, variant, offline))
    end)
  end

  defp splice(body, _start, same, same), do: body

  defp splice(body, start, inner, updated) do
    length = byte_size(inner)
    head = binary_part(body, 0, start)
    tail = binary_part(body, start + length, byte_size(body) - start - length)

    head <> updated <> tail
  end

  defp replace_image_set_quotes(region, variant, offline) do
    escaped = Regex.escape(variant)

    region
    |> replace_pattern(~r/(["'])#{escaped}\1/, fn _, quote -> quote <> offline <> quote end)
    |> String.replace("&quot;" <> variant <> "&quot;", "&quot;" <> offline <> "&quot;")
    |> String.replace("&apos;" <> variant <> "&apos;", "&apos;" <> offline <> "&apos;")
    |> replace_pattern(~r/&#0*34;#{escaped}&#0*34;/, "&#34;" <> offline <> "&#34;")
    |> replace_pattern(
      ~r/(?i:&#x0*22;)#{escaped}(?i:&#x0*22;)/,
      "&#x22;" <> offline <> "&#x22;"
    )
    |> replace_pattern(~r/&#0*39;#{escaped}&#0*39;/, "&#39;" <> offline <> "&#39;")
    |> replace_pattern(
      ~r/(?i:&#x0*27;)#{escaped}(?i:&#x0*27;)/,
      "&#x27;" <> offline <> "&#x27;"
    )
    |> replace_pattern(~r/(^|[\s,(])#{escaped}(?=[\s,)]|$)/, fn _, prefix ->
      prefix <> offline
    end)
  end

  defp replace_pattern(body, pattern, replacement) do
    Regex.replace(pattern, body, replacement)
  end

  defp replace_once(body, from, to) when from == to or from == "", do: body
  defp replace_once(body, from, to), do: String.replace(body, from, to, global: false)

  defp replace_candidate(value, variant, offline) do
    Regex.replace(~r/(^|[\s,])#{Regex.escape(variant)}(?=[\s,]|$)/, value, fn _, prefix ->
      prefix <> offline
    end)
  end

  defp replace_css_urls(body, variant, offline) do
    escaped = Regex.escape(variant)

    body
    |> replace_quoted_url(escaped, offline)
    |> String.replace(~r/(?i:url)\(\s*&quot;#{escaped}&quot;\s*\)/, "url(&quot;#{offline}&quot;)")
    |> String.replace(~r/(?i:url)\(\s*&#0*34;#{escaped}&#0*34;\s*\)/, "url(&#34;#{offline}&#34;)")
    |> String.replace(
      ~r/(?i:url)\(\s*(?i:&#x0*22;)#{escaped}(?i:&#x0*22;)\s*\)/,
      "url(&#x22;#{offline}&#x22;)"
    )
    |> String.replace(~r/(?i:url)\(\s*&#0*39;#{escaped}&#0*39;\s*\)/, "url(&#39;#{offline}&#39;)")
    |> String.replace(~r/(?i:url)\(\s*&apos;#{escaped}&apos;\s*\)/, "url(&apos;#{offline}&apos;)")
    |> String.replace(
      ~r/(?i:url)\(\s*(?i:&#x)0*27;#{escaped}(?i:&#x)0*27;\s*\)/,
      "url(&#x27;#{offline}&#x27;)"
    )
    |> String.replace(~r/(?i:url)\(\s*#{escaped}\s*\)/, "url(#{offline})")
  end

  defp replace_quoted_url(body, escaped, offline) do
    Regex.replace(~r/(?i:url)\(\s*(["'])#{escaped}\1\s*\)/, body, fn _, quote ->
      "url(#{quote}#{offline}#{quote})"
    end)
  end

  defp replace_imports(body, variant, offline) do
    escaped = Regex.escape(variant)

    Enum.reduce(
      [
        {~r/((?i:@import)\s+)(["'])#{escaped}\2/,
         fn _, import, quote -> import <> quote <> offline <> quote end},
        {~r/((?i:@import)\s+)&quot;#{escaped}&quot;/,
         fn _, import -> import <> "&quot;" <> offline <> "&quot;" end},
        {~r/((?i:@import)\s+)&#0*34;#{escaped}&#0*34;/,
         fn _, import -> import <> "&#34;" <> offline <> "&#34;" end},
        {~r/((?i:@import)\s+)(?i:&#x0*22;)#{escaped}(?i:&#x0*22;)/,
         fn _, import -> import <> "&#x22;" <> offline <> "&#x22;" end},
        {~r/((?i:@import)\s+)&#0*39;#{escaped}&#0*39;/,
         fn _, import -> import <> "&#39;" <> offline <> "&#39;" end},
        {~r/((?i:@import)\s+)&apos;#{escaped}&apos;/,
         fn _, import -> import <> "&apos;" <> offline <> "&apos;" end},
        {~r/((?i:@import)\s+)(?i:&#x)0*27;#{escaped}(?i:&#x)0*27;/,
         fn _, import -> import <> "&#x27;" <> offline <> "&#x27;" end}
      ],
      body,
      fn {pattern, replacement}, body ->
        Regex.replace(pattern, body, replacement)
      end
    )
  end

  defp replace_meta(body, variant, offline) do
    Enum.reduce(meta_tags(body), body, fn tag, body ->
      replace_once(body, tag, replace_meta_urls(tag, variant, offline))
    end)
  end

  defp meta_tags(body) do
    ~r/<\s*meta\b(?:[^>"']|"(?:\\.|[^"])*"|'(?:\\.|[^'])*')*>/i
    |> Regex.scan(body)
    |> Enum.map(&hd/1)
  end

  defp replace_meta_urls(tag, variant, offline) do
    escaped = Regex.escape(variant)

    Enum.reduce(
      [
        {~r/(\b(?i:url)\s*=\s*)(["'])#{escaped}\2/,
         fn _, url, quote ->
           url <> quote <> offline <> quote
         end},
        {~r/(\b(?i:url)\s*=\s*)&quot;#{escaped}&quot;/,
         fn _, url ->
           url <> "&quot;" <> offline <> "&quot;"
         end},
        {~r/(\b(?i:url)\s*=\s*)&#0*34;#{escaped}&#0*34;/,
         fn _, url ->
           url <> "&#34;" <> offline <> "&#34;"
         end},
        {~r/(\b(?i:url)\s*=\s*)(?i:&#x0*22;)#{escaped}(?i:&#x0*22;)/,
         fn _, url ->
           url <> "&#x22;" <> offline <> "&#x22;"
         end},
        {~r/(\b(?i:url)\s*=\s*)&#0*39;#{escaped}&#0*39;/,
         fn _, url ->
           url <> "&#39;" <> offline <> "&#39;"
         end},
        {~r/(\b(?i:url)\s*=\s*)&apos;#{escaped}&apos;/,
         fn _, url ->
           url <> "&apos;" <> offline <> "&apos;"
         end},
        {~r/(\b(?i:url)\s*=\s*)(?i:&#x0*27;)#{escaped}(?i:&#x0*27;)/,
         fn _, url ->
           url <> "&#x27;" <> offline <> "&#x27;"
         end},
        {~r/(\b(?i:url)\s*=\s*)(?!["'&])#{escaped}(?=[\s;"'>]|$)/,
         fn _, url -> url <> offline end}
      ],
      tag,
      fn {pattern, replacement}, tag ->
        Regex.replace(pattern, tag, replacement)
      end
    )
  end

  # Only a real module specifier moves. The same text in a string, a comment,
  # prose, or a property call stays.
  defp replace_js(body, variant, offline, opts) do
    regions =
      if MediaType.javascript?(opts[:content_type]) do
        [{0, byte_size(body)}]
      else
        script_regions(body)
      end

    regions
    |> Enum.reverse()
    |> Enum.reduce(body, fn {start, length}, body ->
      source = binary_part(body, start, length)
      splice(body, start, source, replace_js_source(source, variant, offline))
    end)
  end

  defp replace_js_source(source, variant, offline) do
    source
    |> JsParser.spans()
    |> Enum.filter(fn {_at, _len, spec} -> spec == variant end)
    |> Enum.sort_by(fn {at, _len, _spec} -> at end, :desc)
    |> Enum.reduce(source, fn {at, len, _spec}, source ->
      head = binary_part(source, 0, at)
      tail = binary_part(source, at + len, byte_size(source) - at - len)
      head <> offline <> tail
    end)
  end

  defp script_regions(body) do
    ~r/<script\b((?:[^>"']|"(?:\\.|[^"])*"|'(?:\\.|[^'])*')*)>(.*?)<\/script>/is
    |> Regex.scan(body, return: :index)
    |> Enum.flat_map(fn [_tag, {attr_at, attr_len}, {inner_at, inner_len}] ->
      attrs = binary_part(body, attr_at, attr_len)
      if js_script?(attrs), do: [{inner_at, inner_len}], else: []
    end)
  end

  defp js_script?(attrs) do
    type =
      case Regex.run(
             ~r/\btype\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i,
             attrs,
             capture: :all_but_first
           ) do
        nil -> ""
        groups -> groups |> Enum.find("", &(&1 != "")) |> String.trim() |> String.downcase()
      end

    type in ["", "module"] or MediaType.javascript?(type)
  end

  defp replace_attributes(body, variant, offline) do
    escaped = Regex.escape(variant)

    replace_in_tags(body, fn tag ->
      Regex.replace(
        ~r/((?<![\w-])(?i:href|src|poster|data)\s*=\s*)(["'])#{escaped}\2/,
        tag,
        fn _, attr, quote ->
          attr <> quote <> offline <> quote
        end
      )
    end)
  end

  defp replace_unquoted(body, variant, offline) do
    body
    |> replace_unquoted_list(variant, offline)
    |> replace_unquoted_value(variant, offline)
  end

  # A comma separates srcset candidates and is allowed inside an unquoted value.
  defp replace_unquoted_list(body, variant, offline) do
    replace_in_tags(body, fn tag ->
      Regex.replace(
        ~r/((?<![\w-])(?i:imagesrcset|srcset)\s*=\s*)(?!["'])(.+?)(?=[\s>]|\/(?=>)|$)/,
        tag,
        fn _, attr, value ->
          attr <> replace_candidate(value, variant, offline)
        end
      )
    end)
  end

  defp replace_unquoted_value(body, variant, offline) do
    escaped = Regex.escape(variant)

    replace_in_tags(body, fn tag ->
      Regex.replace(
        # A slash is part of a relative path. Only `/>` ends the tag.
        ~r/((?<![\w-])(?i:href|src|poster|data)\s*=\s*)(?!["'])#{escaped}(?=[\s>]|\/(?=>)|$)/,
        tag,
        fn _, attr -> attr <> offline end
      )
    end)
  end

  defp replace_in_tags(body, fun) do
    Regex.replace(~r/<[^>"']*(?:"[^"]*"|'[^']*'|[^>"'])*>/s, body, fn tag ->
      if String.starts_with?(tag, "<!"), do: tag, else: fun.(tag)
    end)
  end

  # A quoted data URL is one token. Replacers must not change the payload
  # when it contains another file name.
  defp lift_quoted_data(body) do
    spans =
      ~r/"(?:\\.|[^"])*"|'(?:\\.|[^'])*'/s
      |> Regex.scan(body, return: :index)
      |> Enum.reduce([], fn [{at, len}], acc ->
        inner = binary_part(body, at + 1, max(len - 2, 0))
        if data_url?(inner), do: [{at, len} | acc], else: acc
      end)

    Enum.reduce(Enum.with_index(spans), {body, []}, fn {{at, len}, i}, {body, saved} ->
      quoted = binary_part(body, at, len)
      token = <<0>> <> "D#{i}" <> <<0>>
      head = binary_part(body, 0, at)
      tail = binary_part(body, at + len, byte_size(body) - at - len)
      {head <> token <> tail, [{token, quoted} | saved]}
    end)
  end

  defp data_url?(url), do: String.match?(url, ~r/^\s*data:/i)

  defp restore_quoted_data(body, saved) do
    Enum.reduce(saved, body, fn {token, quoted}, body ->
      String.replace(body, token, quoted)
    end)
  end
end
