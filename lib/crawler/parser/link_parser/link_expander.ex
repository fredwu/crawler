defmodule Crawler.Parser.LinkParser.LinkExpander do
  @moduledoc """
  Expands a link into a full URL.
  """

  alias Crawler.Linker

  @doc """
  Expands a link into a full URL.

  ## Examples

      iex> LinkExpander.expand({"href", "http://hello.world"}, %{})
      {"href", "http://hello.world"}

      iex> LinkExpander.expand({"href", "page"}, %{referrer_url: "http://hello.world"})
      {"link", "page", "href", "http://hello.world/page"}
  """
  def expand({_src, link} = element, opts) do
    link
    |> is_url?()
    |> transform_link(element, opts)
  end

  defp is_url?(link), do: String.contains?(link, "://")

  defp transform_link(true, element, _opts), do: element

  defp transform_link(false, {src, link}, opts) do
    {"link", link, src, Linker.url(opts[:referrer_url], link)}
  end
end
