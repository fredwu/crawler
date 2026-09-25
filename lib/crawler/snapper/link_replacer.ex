defmodule Crawler.Snapper.LinkReplacer do
  @moduledoc """
  Replaces links found in a page so they work offline.
  """

  alias Crawler.Linker
  alias Crawler.Parser

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
      |> Enum.reduce(body, &modify_body(&2, opts[:url], &1))

    {:ok, new_body}
  end

  defp get_link({_, url}, _opts), do: {url, url}
  defp get_link({_, link, _, url}, _opts), do: {link, url}

  defp modify_body(body, current_url, {raw, resolved}) do
    offline = Linker.offline_link(current_url, resolved)

    Enum.reduce(variants(raw), body, fn variant, body ->
      body
      |> replace_srcset(variant, offline)
      |> replace_css_urls(variant, offline)
      |> replace_imports(variant, offline)
      |> replace_attributes(variant, offline)
    end)
  end

  defp variants(raw) do
    [String.replace(raw, "&", "&amp;"), raw]
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp replace_srcset(body, variant, offline) do
    Regex.replace(~r/(srcset\s*=\s*)(["'])([^"']*)\2/i, body, fn _, attr, quote, value ->
      attr <> quote <> replace_candidate(value, variant, offline) <> quote
    end)
  end

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
    |> String.replace(~r/(?i:url)\(\s*&#0*39;#{escaped}&#0*39;\s*\)/, "url(&#39;#{offline}&#39;)")
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
        {~r/((?i:@import)\s+)&#0*39;#{escaped}&#0*39;/,
         fn _, import -> import <> "&#39;" <> offline <> "&#39;" end},
        {~r/((?i:@import)\s+)(?i:&#x)0*27;#{escaped}(?i:&#x)0*27;/,
         fn _, import -> import <> "&#x27;" <> offline <> "&#x27;" end}
      ],
      body,
      fn {pattern, replacement}, body ->
        Regex.replace(pattern, body, replacement)
      end
    )
  end

  defp replace_attributes(body, variant, offline) do
    Regex.replace(
      ~r/((?i:href|src|poster)\s*=\s*)(["'])#{Regex.escape(variant)}\2/,
      body,
      fn _, attr, quote ->
        attr <> quote <> offline <> quote
      end
    )
  end
end
