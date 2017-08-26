defmodule Crawler.Parser.CssParser do
  @moduledoc """
  Parses CSS files.
  """

  @url_unsafe_chars ")'\""

  @doc """
  ## Examples

      iex> CssParser.parse(
      iex>   "img { url(http://hello.world) }"
      iex> )
      [{"link", [{"href", "http://hello.world"}], []}]

      iex> CssParser.parse(
      iex>   "@font-face { src: url('icons.ttf') format('truetype'); }"
      iex> )
      [{"link", [{"href", "icons.ttf"}], []}]
  """
  def parse(body) do
    ~r{url\(['"]?([^#{@url_unsafe_chars}]+)['"]?\)}
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&prep_css_element/1)
  end

  defp prep_css_element([link]) do
    {"link", [{"href", link}], []}
  end
end
