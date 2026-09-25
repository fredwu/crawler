defmodule Crawler.Parser.CssParser do
  @moduledoc """
  Parses CSS files.
  """

  @import_pattern ~r/@import\s+(?!url\()['"](?!data:)([^'"]+)['"]/i
  @url_pattern ~r/url\(\s*(?:'((?!data:)[^']*)'|"((?!data:)[^"]*)"|(?!['"])((?!data:)[^)\s]+))\s*\)/i

  @doc """
  Parses CSS files.

  ## Examples

      iex> CssParser.parse(
      iex>   "img { url(http://hello.world) }"
      iex> )
      [{"link", [{"href", "http://hello.world"}], []}]

      iex> CssParser.parse(
      iex>   "@font-face { src: url('icons.ttf') format('truetype'); }"
      iex> )
      [{"link", [{"href", "icons.ttf"}], []}]

      iex> CssParser.parse(
      iex>   "@font-face { src: url('data:application/blah'); }"
      iex> )
      []

      iex> CssParser.parse("@import 'other.css';")
      [{"link", [{"href", "other.css"}], []}]

      iex> CssParser.parse("@import url(\\"nested.css\\");")
      [{"link", [{"href", "nested.css"}], []}]

      iex> CssParser.parse("body { background: url( \\"spaced.png\\" ); }")
      [{"link", [{"href", "spaced.png"}], []}]

      iex> CssParser.parse("@font-face { src: url( 'font.woff2' ); }")
      [{"link", [{"href", "font.woff2"}], []}]
  """
  def parse(body) when is_binary(body) do
    ((@import_pattern |> captures(body)) ++ (@url_pattern |> captures(body)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(&prep_css_element/1)
  end

  def parse(_body), do: []

  defp captures(regex, body) do
    regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn groups -> Enum.find(groups, &(&1 != "")) end)
    |> Enum.reject(&is_nil/1)
  end

  defp prep_css_element(link) do
    {"link", [{"href", link}], []}
  end
end
