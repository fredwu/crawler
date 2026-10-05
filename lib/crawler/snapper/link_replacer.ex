defmodule Crawler.Snapper.LinkReplacer do
  @moduledoc """
  Replaces links found in a page so they work offline.

  Removes integrity metadata from rewritten script, stylesheet, modulepreload,
  and script or style preload references because saved resource bytes can change.
  """

  alias Crawler.Linker
  alias Crawler.MediaType
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer.Css
  alias Crawler.Snapper.LinkReplacer.Html
  alias Crawler.Snapper.LinkReplacer.Javascript
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
    raw_links = links(body, opts)
    {body, saved} = RawText.protect(body, opts)
    document_links = if saved == [], do: raw_links, else: links(body, opts)

    new_body =
      body
      |> rewrite_body(document_links, opts)
      |> Html.drop_base(opts)
      |> RawText.restore(saved, fn source, source_opts ->
        rewrite_opts = opts |> Map.delete(:javascript_goal) |> Map.merge(source_opts)
        rewrite_body(source, raw_links, rewrite_opts)
      end)

    {:ok, new_body}
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

  defp rewrite_body(body, [], _opts), do: body

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
  end

  defp get_link({_, url}, _opts), do: {url, url}
  defp get_link({_, link, _, url}, _opts), do: {link, url}

  defp modify_body(body, _opts, {"", _offline}), do: body

  defp modify_body(body, opts, {raw, offline}) do
    cond do
      MediaType.css?(opts[:content_type]) ->
        Css.replace(body, raw, offline, entity_quotes: false)

      MediaType.javascript?(opts[:content_type]) ->
        Javascript.replace(body, raw, offline, Map.get(opts, :javascript_goal, :module))

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
