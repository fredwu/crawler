defmodule Crawler.Parser.LinkParser.LinkExpander do
  @moduledoc """
  Expands a link into a full URL.
  """

  alias Crawler.URL

  @doc """
  Expands a link into a full URL.

  ## Examples

      iex> LinkExpander.expand({"href", "http://hello.world"}, %{})
      {"href", "http://hello.world"}

      iex> LinkExpander.expand({"href", "page"}, %{referrer_url: "http://hello.world"})
      {"link", "page", "href", "http://hello.world/page"}
  """
  def expand({src, link}, opts) do
    base = opts[:referrer_url] || opts[:url]

    case URL.resolve(link, base) do
      {:ok, url} ->
        if url == link do
          {src, url}
        else
          {"link", link, src, url}
        end

      :skip ->
        nil
    end
  end
end
