defmodule Crawler.Replacer do
  @moduledoc """
  Replaces links found in a page so they work offline.
  """

  alias Crawler.{Parser, Linker}

  @doc """
  ## Examples

      iex> Replacer.replace_links(
      iex>   "<a href='http://another.domain/page.html'></a>",
      iex>   url: "http://main.domain/dir/page",
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex> )
      {:ok, "<a href='../../another.domain/page.html'></a>"}

      iex> Replacer.replace_links(
      iex>   "<a href='http://another.domain/dir/page.html'></a>",
      iex>   url: "http://main.domain/page",
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex> )
      {:ok, "<a href='../another.domain/dir/page.html'></a>"}

      iex> Replacer.replace_links(
      iex>   "<a href='http://another.domain/dir/page'></a>",
      iex>   url: "http://main.domain/dir/page",
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex> )
      {:ok, "<a href='../../another.domain/dir/page/index.html'></a>"}

      iex> Replacer.replace_links(
      iex>   "<a href='/dir/page2.html'></a>",
      iex>   url: "http://main.domain/dir/page",
      iex>   referrer_url: "http://main.domain/dir/page",
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex> )
      {:ok, "<a href='../../main.domain/dir/page2.html'></a>"}
  """
  def replace_links(body, opts) do
    new_body = body
    |> Parser.parse_links(opts, &get_link/2)
    |> List.flatten
    |> Enum.reduce(body, &modify_body(&2, opts[:url], &1))

    {:ok, new_body}
  end

  defp get_link({_, url}, _opts),          do: url
  defp get_link({_, link, _, url}, _opts), do: [link, url]

  defp modify_body(body, current_url, link) do
    String.replace(body, ~r/(href=['"])#{link}(['"])/, modify_link(current_url, link))
  end

  defp modify_link(current_url, link) do
    "\\1" <> Linker.offline_link(current_url, link) <> "\\2"
  end
end
