defmodule Crawler.Snapper.LinkReplacer do
  @moduledoc """
  Replaces links found in a page so they work offline.

  Removes integrity metadata from rewritten script, stylesheet, and modulepreload references because saved resource bytes can change.
  """

  alias Crawler.Linker
  alias Crawler.MediaType
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer.Css
  alias Crawler.Snapper.LinkReplacer.Html
  alias Crawler.Snapper.LinkReplacer.Javascript
  alias Crawler.Snapper.LinkReplacer.RawText

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
    raw_links = links(body, opts)
    {body, saved} = RawText.protect(body, opts)
    document_links = if saved == [], do: raw_links, else: links(body, opts)

    new_body =
      body
      |> rewrite_body(document_links, opts)
      |> Html.drop_base(opts)
      |> RawText.restore(saved, fn source, type ->
        rewrite_body(source, raw_links, Map.put(opts, :content_type, type))
      end)

    {:ok, new_body}
  end

  defp links(body, opts) do
    body
    |> Parser.parse_links(opts, &get_link/2)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(
      fn {raw, _resolved} -> raw |> variants(opts) |> hd() |> byte_size() end,
      :desc
    )
    |> Enum.map(fn {raw, resolved} ->
      {raw, Linker.offline_link(opts[:url], with_fragment(resolved, raw))}
    end)
  end

  defp rewrite_body(body, [], _opts), do: body

  defp rewrite_body(body, links, opts) do
    prefix = replacement_prefix([body | Enum.map(links, &elem(&1, 1))])

    {body, replacements} =
      links
      |> Enum.with_index()
      |> Enum.reduce({body, %{}}, fn {{raw, offline}, index}, {body, replacements} ->
        token = prefix <> Integer.to_string(index) <> <<0>>
        {modify_body(body, opts, {raw, token}), Map.put(replacements, token, offline)}
      end)

    tokens = Map.keys(replacements)

    body
    |> Html.drop_rewritten_integrity(tokens, opts)
    |> String.replace(tokens, &Map.fetch!(replacements, &1))
  end

  defp replacement_prefix(values, prefix \\ <<0>> <> "L") do
    if Enum.any?(values, &String.contains?(&1, prefix)) do
      replacement_prefix(values, prefix <> "L")
    else
      prefix
    end
  end

  defp get_link({_, url}, _opts), do: {url, url}
  defp get_link({_, link, _, url}, _opts), do: {link, url}

  defp modify_body(body, opts, {raw, offline}) do
    Enum.reduce(variants(raw, opts), body, fn variant, body ->
      rewrite_variant(body, variant, offline, opts)
    end)
  end

  defp rewrite_variant(body, variant, _offline, _opts) when variant == "", do: body

  defp rewrite_variant(body, variant, offline, opts) do
    if String.contains?(body, variant) do
      replace_variant(body, variant, offline, opts)
    else
      body
    end
  end

  defp replace_variant(body, variant, offline, opts) do
    cond do
      MediaType.css?(opts[:content_type]) ->
        Css.replace(body, variant, offline, entity_quotes: false)

      MediaType.javascript?(opts[:content_type]) ->
        Javascript.replace(body, variant, offline)

      true ->
        body
        |> Html.replace_srcset(variant, offline)
        |> Html.replace_style_attributes(variant, offline)
        |> Html.replace_meta(variant, offline)
        |> Html.replace_attributes(variant, offline)
        |> Html.replace_unquoted(variant, offline)
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

  defp variants(raw, opts) do
    if MediaType.css?(opts[:content_type]) or MediaType.javascript?(opts[:content_type]) do
      [raw]
    else
      escaped = String.replace(raw, "&", "&amp;")

      [String.replace(escaped, "\"", "&quot;"), escaped, raw]
      |> Enum.uniq()
      |> Enum.sort_by(&byte_size/1, :desc)
    end
  end
end
