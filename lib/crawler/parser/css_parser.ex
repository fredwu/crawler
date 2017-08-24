defmodule Crawler.Parser.CssParser do
  @moduledoc """
  Parses CSS files.
  """

  @doc """
  ## Examples

      iex> CssParser.parse(
      iex>   "img { url(http://hello.world) }"
      iex> )
      [{"link", [{"href", "http://hello.world"}], []}]
  """
  def parse(body) do
    ~r{url\(['"]?(.*)['"]?\)}
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&prep_css_element/1)
  end

  defp prep_css_element([link]) do
    {"link", [{"href", link}], []}
  end
end
