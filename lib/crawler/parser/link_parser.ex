defmodule Crawler.Parser.LinkParser do
  @moduledoc """
  Parses links and transforms them if necessary.
  """

  alias Crawler.Linker

  @doc """
  ## Examples

      iex> LinkParser.parse(
      iex>   {"a", [{"hello", "world"}, {"href", "http://hello.world"}], []},
      iex>   [],
      iex>   &Kernel.inspect(&1, &2)
      iex> )
      "{\\\"href\\\", \\\"http://hello.world\\\"}"
  """
  def parse({"a", attrs, _}, opts, link_handler) do
    with {"href", link} <- detect_link(attrs),
         element        <- expand_link_into_url({"href", link}, opts)
    do
      link_handler.(element, opts)
    end
  end

  defp detect_link(attrs) do
    Enum.find(attrs, fn(attr) ->
      Kernel.match?({"href", _}, attr)
    end)
  end

  defp expand_link_into_url(element = {"href", link}, opts) do
    link
    |> is_url?
    |> transform_link(element, opts)
  end

  defp is_url?(link), do: String.contains?(link, "://")

  defp transform_link(true, element, _opts), do: element

  defp transform_link(false, {"href", link}, opts) do
    {"link", link, "href", Linker.url(opts[:referrer_url], link)}
  end
end
